# Runtime Binary Manifest

Generated from `build.yaml`; run `just prepare` to regenerate.

First-party binaries shipped in the final runtime image.

| Binary | Version | Build toolchain | Source | Checksum | License |
|---|---|---|---|---|---|
| ACFS | 0.6.0 | Go 1.27.0 | <https://github.com/getarcaneapp/kit/releases/tag/acfs/v0.6.0> | Built from source in-image at the pinned kit tag (module checksums verified via sum.golang.org) | BSD-3-Clause |

Third-party binaries shipped in the final runtime image.

| Binary | Version | Source | Checksum | License |
|---|---|---|---|---|
| Trivy | 0.74.0 | <https://github.com/aquasecurity/trivy/releases/tag/v0.74.0> | [trivy.txt](trivy.txt) | Apache-2.0 |
| BusyBox | 1.38.0 | <https://busybox.net/downloads/busybox-1.38.0.tar.bz2> | [busybox.sha256](busybox.sha256) | GPL-2.0-only |

The ACFS binary is built from source in-image from the pinned kit
monorepo tag, with Go module checksums verified via sum.golang.org. The CA certificate bundle is copied from
Alpine 3.24 during the build and is not treated as a separately versioned
executable binary.
