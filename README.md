# Arcane Toolbox Image Build Spec

## Purpose

This repository should produce the external Arcane toolbox image used for two
runtime jobs:

1. Volume helper containers that Arcane starts to inspect, archive, restore,
   and clean up Docker volumes.
2. Trivy scan containers that Arcane starts explicitly to scan images, files,
   or mounted targets.

The goal is to give Arcane a single trusted image instead of falling back to
pulling `busybox:stable-musl` for helper work and the upstream Trivy image for
security scanning.

## Required Tool Inventory

Arcane currently needs the image to provide the following commands and runtime
assets.

### Volume helper commands

- `sh`
- `sleep`
- `find`
- `stat`
- `readlink`
- `head`
- `rm`
- `mkdir`
- `mv`
- `rmdir`
- `mktemp`
- `tar`
- `test`

### Security scanning command

- `trivy`

### Runtime support assets

- CA certificates so `trivy` can reach registries and vulnerability feeds over
  TLS
- A writable `/tmp`
- A writable cache location at `/root/.cache`
- Noninteractive shell behavior suitable for `sh -c "..."` command execution

## Runtime Contract

Arcane will treat this image as a general-purpose toolbox image, not as a
single-purpose Trivy image. The published image must satisfy all of the
following:

- Arcane can use the same image for both volume helper containers and Trivy
  scan containers.
- Arcane will invoke commands explicitly, for example `sleep`, `sh -c`, `tar`,
  or `trivy image ...`.
- The image must not depend on a Trivy-specific entrypoint.
- `trivy` must exist at a stable path, preferably `/usr/local/bin/trivy`.
- All required helper commands must be discoverable on `PATH`.
- The image must behave correctly when started with no TTY and no interactive
  init system.
- The image must include a writable `/tmp` and `/root/.cache`.
- The image should remain compatible with mounted Docker resources such as the
  Docker socket or mounted volumes when Arcane provides them at runtime.

### Command execution expectations

Arcane should be able to run commands like these without any wrapper script or
entrypoint translation:

```sh
sleep 300
sh -c 'find /volume -maxdepth 2 -type f | head'
tar -C /volume -cf /tmp/archive.tar .
tar -C /restore -xf /tmp/archive.tar
trivy --version
trivy image --cache-dir /root/.cache/trivy ghcr.io/example/app:1.2.3
```

## Recommended Repository Shape

Keep the repo small and explicit. A minimal layout is:

```text
.
├── busybox.config
├── CHANGELOG.md
├── Dockerfile
├── README.md
├── checksums/
│   ├── busybox-1.37.0.tar.bz2.sha256
│   └── trivy_0.69.3_checksums.txt
├── scripts/
│   └── validate.sh
└── third_party/
    └── manifest.md
```

- `Dockerfile` builds the image.
- `busybox.config` defines the minimal BusyBox applet set required by Arcane.
- `checksums/` stores the expected digests for downloaded binaries.
- `scripts/validate.sh` runs the pre-publish validation steps locally or in CI.
- `third_party/manifest.md` records provenance metadata for each bundled binary.

## Recommended Dockerfile Shape

Use a multi-stage Dockerfile that downloads pinned artifacts in dedicated
builder stages and copies only the runtime essentials into the final image.

### Build requirements

- Pin exact versions with `ARG` values such as `TRIVY_VERSION` and
  `BUSYBOX_VERSION`.
- Download artifacts from explicit upstream release URLs.
- Verify checksums during the build before extracting, compiling, or copying
  binaries.
- Prefer static binaries where possible.
- Avoid `curl | sh` or other implicit installer patterns.

### Final image requirements

- Use `scratch`, distroless, or another very small base only if it still
  satisfies the shell and utility contract.
- If Arcane's helper behavior depends on shell-compatible utilities, prefer a
  minimal runtime based on a static BusyBox binary plus copied certs.
- Place custom binaries in `/usr/local/bin`.
- Ensure helper tools are on `PATH`.
- Create predictable writable paths:
  - `/tmp`
  - `/root/.cache`
- Keep the entrypoint neutral with `ENTRYPOINT []` or no entrypoint override so
  Arcane can choose the command directly.

### Current pinned inputs

The implementation in this repository currently pins:

- Trivy `0.69.3`
- BusyBox source `1.37.0`, compiled with `CONFIG_STATIC=y`

### Recommended implementation pattern

The following Dockerfile shape is the recommended baseline:

```dockerfile
# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.23
ARG TRIVY_VERSION=0.69.3
ARG BUSYBOX_VERSION=1.37.0

FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS trivy-fetcher
ARG TRIVY_VERSION
ARG TARGETARCH

RUN apk add --no-cache ca-certificates curl tar

WORKDIR /work

COPY checksums/trivy_0.69.3_checksums.txt /checksums/trivy_checksums.txt

RUN case "${TARGETARCH}" in \
      amd64) trivy_arch='64bit' ;; \
      arm64) trivy_arch='ARM64' ;; \
      *) exit 1 ;; \
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
    yes "" | make oldconfig && \
    make -j"$(getconf _NPROCESSORS_ONLN)"

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
```

### Notes on the recommended shape

- `scratch` is acceptable if the final tree includes a working `/bin/sh`,
  required BusyBox applets, certificates, and writable directories.
- This repository compiles BusyBox from verified upstream source because the
  source release has an official checksum and still produces a small static
  runtime binary.
- If `trivy` requires shared libraries for a chosen architecture, switch the
  final stage to a tiny compatible runtime base and keep the rest of the layout
  unchanged.
- The final image should not include package managers, compilers, shells beyond
  the required helper shell, or debugging tools that Arcane does not use.

## Tool Sourcing Policy

Every shipped binary must be tracked with provenance metadata. At minimum,
record the following in `third_party/manifest.md`:

- Binary name
- Upstream source URL
- Exact version
- Exact checksum or digest
- License
- Notes on whether the artifact is static or requires runtime libraries

### Policy rules

- Pin exact versions and digests.
- Prefer static binaries where possible.
- Prefer direct upstream release artifacts over package-manager installs.
- Avoid package-manager installs in the final image unless they are required for
  CA certificates or runtime library compatibility.
- Treat checksum updates as code-reviewed changes.
- Keep a changelog entry whenever a binary version changes or a CVE response
  requires rebuilding the image.

## Validation Before Publishing

Validate the built image before every publish. At minimum, the validation must
prove the runtime contract, not just that the image builds.

### Required checks

- Run every helper command Arcane uses today:

```sh
docker run --rm <image> sh -c 'command -v sh sleep find stat readlink head rm mkdir mv rmdir mktemp tar test'
```

- Verify Trivy is installed at the expected path and responds normally:

```sh
docker run --rm <image> /usr/local/bin/trivy --version
docker run --rm <image> trivy --version
```

- Verify tar create and extract workflows used by backup and restore:

```sh
docker run --rm -v "$PWD:/work" <image> sh -c '
  mkdir -p /tmp/src /tmp/dst &&
  printf hello >/tmp/src/file.txt &&
  tar -C /tmp/src -cf /tmp/test.tar . &&
  tar -C /tmp/dst -xf /tmp/test.tar &&
  test "$(head -n 1 /tmp/dst/file.txt)" = hello
'
```

- Verify symlink and metadata behavior used by the volume browser:

```sh
docker run --rm <image> sh -c '
  mkdir -p /tmp/tree &&
  printf data >/tmp/tree/file.txt &&
  /bin/busybox ln -s /tmp/tree/file.txt /tmp/tree/link.txt &&
  find /tmp/tree -maxdepth 1 &&
  stat /tmp/tree/file.txt &&
  test "$(readlink /tmp/tree/link.txt)" = /tmp/tree/file.txt &&
  test "$(head -n 1 /tmp/tree/file.txt)" = data
'
```

- Verify predictable temporary and cache paths:

```sh
docker run --rm <image> sh -c 'test -w /tmp && mkdir -p /root/.cache && test -w /root/.cache'
```

- If Arcane will use Trivy to scan local Docker images through a mounted Docker
  socket, verify that assumption explicitly:

```sh
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  <image> trivy image --cache-dir /root/.cache alpine:3.22
```

### Release gates

Do not publish unless all validation steps pass for each supported target
architecture.

## Publishing and Consumption

Publish the image to the chosen registry with:

- Semantic version tags such as `v1.0.0`
- A floating major tag if desired, such as `v1`
- Immutable digests for production consumption

### Consumption rules

- Arcane should consume a pinned digest as the default `toolboxImage`.
- Tags may be used for discovery, but the runtime default should resolve to a
  specific immutable digest.
- Keep a changelog that records:
  - Binary version bumps
  - Checksum changes
  - CVE response rebuilds
  - Contract changes that require Arcane coordination

## Implementation Checklist

The first implementation of this repo should include:

- A `Dockerfile` matching the multi-stage shape above
- Pinned Trivy and BusyBox artifacts with checksum verification
- CA certificates in the final runtime image
- `/usr/local/bin/trivy`
- BusyBox-linked helper commands on `PATH`
- Writable `/tmp` and `/root/.cache`
- A neutral entrypoint
- A provenance manifest for all bundled binaries
- A validation script that exercises the runtime contract
- Release documentation that tells Arcane which digest to consume by default

## Assumptions

- This toolbox image lives in its own repository.
- Arcane will eventually consume one `toolboxImage` per environment.
- Normal Arcane operation should stop pulling `busybox:stable-musl` and the
  upstream Trivy image once this image is adopted.
