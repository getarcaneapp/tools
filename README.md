# Arcane Toolbox Image

Minimal runtime toolbox image for Arcane volume browsing, security scans and other tools.

## What this image contains

The final image is built `FROM scratch` and contains only:

- `trivy` (installed at `/usr/local/bin/trivy`)
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
`third_party/manifest.md` and the `checksums/` directory.
