# Arcane Toolbox Image

Minimal runtime toolbox image for Arcane volume browsing, security scans and other tools.

## What this image contains

The final image is built `FROM scratch` and contains only:

- `trivy` (installed at `/usr/local/bin/trivy`)
- The first-party `acfs` binary (installed at `/usr/local/bin/acfs`)
  for root-confined filesystem reads, traversal, and batch mutations
- A statically linked BusyBox binary at `/bin/busybox`
- A curated set of BusyBox applets exposed as standalone commands in `/bin`:
  - `sh`
  - `sleep`
  - `find`
  - `gzip`
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
- CA certificates bundle at `/etc/ssl/certs/ca-certificates.crt`
- Writable runtime directories:
  - `/tmp` (mode `1777`)
  - `/root/.cache`

## Versions and provenance

Pinned versions, source URLs, and checksum verification details are tracked in
[`checksums/manifest.md`](checksums/manifest.md) (generated from `build.yaml`
during builds and updates) alongside the per-binary checksum files in `checksums/`.
`acfs` is built from source in-image at a pinned release tag of the
[`getarcaneapp/kit`](https://github.com/getarcaneapp/kit) monorepo
(tags `acfs/vX.Y.Z`); Go module dependencies are verified via sum.golang.org.

## Trivy database mirror

This repo also mirrors the three Trivy OCI databases needed for
[Trivy self-hosting](https://trivy.dev/docs/latest/guide/advanced/self-hosting/)
to `ghcr.io/getarcaneapp` and `docker.io/getarcaneapp` on a 6-hour cron:

| Database | GHCR | Docker Hub |
|---|---|---|
| Vulnerability DB    | `ghcr.io/getarcaneapp/trivy-db:2`          | `docker.io/getarcaneapp/trivy-db:2`          |
| Java DB             | `ghcr.io/getarcaneapp/trivy-java-db:1`     | `docker.io/getarcaneapp/trivy-java-db:1`     |
| Checks (misconfig)  | `ghcr.io/getarcaneapp/trivy-checks:1`      | `docker.io/getarcaneapp/trivy-checks:1`      |

The Docker Hub namespace is in the
[Docker Sponsored Open Source](https://www.docker.com/community/open-source/) program,
so pulls from it are not rate-limited.

The mirror runs via
[`.depot/workflows/mirror-trivy-db.yaml`](.depot/workflows/mirror-trivy-db.yaml)
(Depot CI, production) with an equivalent
[`.github/workflows/mirror-trivy-db.yaml`](.github/workflows/mirror-trivy-db.yaml),
and copies upstream OCI artifacts verbatim — the mirrored digest matches
upstream exactly. Mirror entries are declared in [`build.yaml`](build.yaml)
under `mirrors:`. Mirrored artifacts are signed with the same cosign key as
`ghcr.io/getarcaneapp/tools` and have GitHub provenance attestations attached.

The toolbox image itself is published to both `ghcr.io/getarcaneapp/tools`
and `docker.io/getarcaneapp/tools` on `v*` tag pushes, using the same tags
(`X.Y.Z`, `X.Y`, `X`, `latest`, `sha-<commit>`) on both registries.

To point Trivy at the mirror (Trivy tries the listed repositories in order):

```sh
trivy image \
  --db-repository            docker.io/getarcaneapp/trivy-db:2,ghcr.io/getarcaneapp/trivy-db:2 \
  --java-db-repository       docker.io/getarcaneapp/trivy-java-db:1,ghcr.io/getarcaneapp/trivy-java-db:1 \
  --checks-bundle-repository docker.io/getarcaneapp/trivy-checks:1,ghcr.io/getarcaneapp/trivy-checks:1 \
  <image>
```

## Building

The build is driven by `build.yaml` (versions, target platforms, BusyBox
config flags, applet symlinks) and orchestrated by a `Justfile`.

Prereqs:

- [`just`](https://just.systems/)
- [`yq`](https://github.com/mikefarah/yq) v4+
- `docker` with `buildx`

Common recipes:

```sh
just                       # list commands
just build                 # build and load ghcr.io/getarcaneapp/tools:dev
just test                  # check the built image's runtime contract
just test custom-image:tag # check another image
just -- build --platform linux/arm64 # build for a specific platform
just -- build --push --platform linux/amd64,linux/arm64 -t ghcr.io/getarcaneapp/tools:latest
DRY_RUN=1 just update       # preview upstream version updates
just update acfs           # update only ACFS
just update                # update all versions, checksums, and the manifest
DRY_RUN=1 just mirror       # resolve mirror digests without pushing
just mirror                # mirror Trivy databases
just clean                 # remove dist/
```

`just update` updates every pinned version by default. Pass one or more
component names (`alpine`, `trivy`, `busybox`, or `acfs`) to update only those
inputs, for example `just update acfs`. Trivy and BusyBox checksums are refreshed
from their official upstream release files. ACFS's release checksum manifest is
validated by the updater and fetched again during the image build; Alpine is
consumed as a container base image and has no local checksum file.
