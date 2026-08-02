# Third-Party Manifest

Generated from `build.yaml`; run `just prepare` to regenerate.

Third-party binaries shipped in the final runtime image.

| Binary | Version | Source | Integrity | License |
|---|---|---|---|---|
| Trivy | 0.72.0 | <https://github.com/aquasecurity/trivy/releases/tag/v0.72.0> | [trivy.txt](trivy.txt) | Apache-2.0 |
| BusyBox | 1.37.0 | <https://busybox.net/downloads/busybox-1.37.0.tar.bz2> | [busybox.sha256](busybox.sha256) | GPL-2.0-only |
| Rustic | 0.11.2 | <https://crates.io/crates/rustic-rs/0.11.2> | Cargo registry checksum and locked dependencies | Apache-2.0 OR MIT |

The CA certificate bundle is copied from Alpine 3.23 during the build and is not
treated as a separately versioned executable binary.
