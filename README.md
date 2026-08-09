# Arcane Toolbox Image

Minimal runtime toolbox image for Arcane volume browsing, security scans and other tools.

## What this image contains

The final image is built `FROM scratch` and contains only:

- `trivy` (installed at `/usr/local/bin/trivy`)
- The first-party `acfs` binary (installed at `/usr/local/bin/acfs`)
  for root-confined listing, walking, metadata, and streaming filesystem I/O
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
by `just prepare`) alongside the per-binary checksum files in `checksums/`.
`acfs` is pinned to an ACFS module release and verified against the
checksum manifest generated for that release by GoReleaser.

## Trivy database mirror

This repo also mirrors the three Trivy OCI databases needed for
[Trivy self-hosting](https://trivy.dev/docs/latest/guide/advanced/self-hosting/)
to `ghcr.io/getarcaneapp` on a 6-hour cron:

| Database | Mirror reference |
|---|---|
| Vulnerability DB    | `ghcr.io/getarcaneapp/trivy-db:2` |
| Java DB             | `ghcr.io/getarcaneapp/trivy-java-db:1` |
| Checks (misconfig)  | `ghcr.io/getarcaneapp/trivy-checks:1` |

The mirror runs via
[`.github/workflows/mirror-trivy-db.yaml`](.github/workflows/mirror-trivy-db.yaml)
and copies upstream OCI artifacts verbatim — the mirrored digest matches
upstream exactly. Mirror entries are declared in [`build.yaml`](build.yaml)
under `mirrors:`. Mirrored artifacts are signed with the same cosign key as
`ghcr.io/getarcaneapp/tools` and have GitHub provenance attestations attached.

To point Trivy at the mirror:

```sh
trivy image \
  --db-repository            ghcr.io/getarcaneapp/trivy-db:2 \
  --java-db-repository       ghcr.io/getarcaneapp/trivy-java-db:1 \
  --checks-bundle-repository ghcr.io/getarcaneapp/trivy-checks:1 \
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
just              # list recipes
just versions     # print resolved values from build.yaml
just prepare      # render dist/busybox.config and dist/applets.txt from YAML
just build        # build image for the local platform, load as arcane-toolbox:dev
just build-multi  # validate all published architectures without loading or pushing
just validate     # run runtime-contract checks against arcane-toolbox:ci
just update-dry   # show the latest upstream versions without changing files
just update       # update all versions, checksums, and the generated manifest
just clean        # remove dist/
```

`just update` updates every pinned version by default. Pass one or more
component names (`alpine`, `trivy`, or `busybox`) to update only those inputs,
for example `just update trivy`. Trivy and BusyBox checksums are refreshed from
their official upstream release files; Alpine is consumed as a container base
image and has no local checksum file.
