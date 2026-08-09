# Runtime Binary Manifest

Generated from `build.yaml`; run `just prepare` to regenerate.

First-party binaries shipped in the final runtime image.

| Binary | Version | Build toolchain | Source | Checksum | License |
|---|---|---|---|---|---|
| ACFS | 0.2.0 | Go 1.26.5 | <https://github.com/getarcaneapp/acfs/releases/tag/v0.2.0> | GoReleaser `acfs_checksums.txt` release asset | BSD-3-Clause |

Third-party binaries shipped in the final runtime image.

| Binary | Version | Source | Checksum | License |
|---|---|---|---|---|
| Trivy | 0.73.0 | <https://github.com/aquasecurity/trivy/releases/tag/v0.73.0> | [trivy.txt](trivy.txt) | Apache-2.0 |
| BusyBox | 1.38.0 | <https://busybox.net/downloads/busybox-1.38.0.tar.bz2> | [busybox.sha256](busybox.sha256) | GPL-2.0-only |

The ACFS binary and its checksum manifest are produced by the ACFS
module GoReleaser configuration. The CA certificate bundle is copied from
Alpine 3.24 during the build and is not treated as a separately versioned
executable binary.
