# Third-Party Manifest

Generated from `build.yaml`; run `just prepare` to regenerate.

Third-party binaries shipped in the final runtime image.

| Binary | Version | Source | Checksum | License |
|---|---|---|---|---|
| Trivy | 0.73.0 | <https://github.com/aquasecurity/trivy/releases/tag/v0.73.0> | [trivy.txt](trivy.txt) | Apache-2.0 |
| BusyBox | 1.38.0 | <https://busybox.net/downloads/busybox-1.38.0.tar.bz2> | [busybox.sha256](busybox.sha256) | GPL-2.0-only |

The CA certificate bundle is copied from Alpine 3.24 during the build and is not
treated as a separately versioned executable binary.
