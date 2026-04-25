# Justfile — orchestrates the arcane-toolbox build from build.yaml.
# Prereqs: just, yq (github.com/mikefarah/yq, v4+), docker (with buildx).

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

config := "build.yaml"

# Resolved at startup so a broken build.yaml fails before any work runs.
alpine_version  := `yq -r '.versions.alpine'  build.yaml`
trivy_version   := `yq -r '.versions.trivy'   build.yaml`
busybox_version := `yq -r '.versions.busybox' build.yaml`
image_name      := `yq -r '.image.name'       build.yaml`
local_tag       := `yq -r '.image.local_tag'  build.yaml`
ci_tag          := `yq -r '.image.ci_tag'     build.yaml`
validate_plat   := `yq -r '.platforms.validate' build.yaml`
publish_plats   := `yq -r '.platforms.publish | join(",")' build.yaml`

default: list

list:
    @just --list

versions:
    @echo "alpine:    {{alpine_version}}"
    @echo "trivy:     {{trivy_version}}"
    @echo "busybox:   {{busybox_version}}"
    @echo "image:     {{image_name}}"
    @echo "local_tag: {{local_tag}}"
    @echo "ci_tag:    {{ci_tag}}"
    @echo "validate:  {{validate_plat}}"
    @echo "publish:   {{publish_plats}}"

# Materialize YAML-derived inputs the Dockerfile expects.
prepare: manifest
    mkdir -p dist
    yq -r '.busybox.config[] | . + "=y"' {{config}} > dist/busybox.config
    yq -r '.busybox.applets[]'           {{config}} > dist/applets.txt

# Regenerate checksums/manifest.md from build.yaml.
manifest:
    @printf '# Third-Party Manifest\n\nGenerated from `build.yaml`; run `just prepare` to regenerate.\n\nThird-party binaries shipped in the final runtime image.\n\n| Binary | Version | Source | Checksum | License |\n|---|---|---|---|---|\n| Trivy | %s | <https://github.com/aquasecurity/trivy/releases/tag/v%s> | [trivy.txt](trivy.txt) | Apache-2.0 |\n| BusyBox | %s | <https://busybox.net/downloads/busybox-%s.tar.bz2> | [busybox.sha256](busybox.sha256) | GPL-2.0-only |\n\nThe CA certificate bundle is copied from Alpine %s during the build and is not\ntreated as a separately versioned executable binary.\n' \
        '{{trivy_version}}' '{{trivy_version}}' \
        '{{busybox_version}}' '{{busybox_version}}' \
        '{{alpine_version}}' \
        > checksums/manifest.md

# Build for the validate platform, load into local docker as local_tag.
build: prepare
    docker buildx build \
        --load \
        --platform {{validate_plat}} \
        --build-arg ALPINE_VERSION={{alpine_version}} \
        --build-arg TRIVY_VERSION={{trivy_version}} \
        --build-arg BUSYBOX_VERSION={{busybox_version}} \
        -t {{local_tag}} \
        .

# Build the CI validation image. Tag is parameterized so the workflow can
# pass arcane-toolbox:ci explicitly.
build-ci tag=ci_tag: prepare
    docker buildx build \
        --load \
        --platform {{validate_plat}} \
        --build-arg ALPINE_VERSION={{alpine_version}} \
        --build-arg TRIVY_VERSION={{trivy_version}} \
        --build-arg BUSYBOX_VERSION={{busybox_version}} \
        -t {{tag}} \
        .

# Run the runtime contract checks against an already-built image.
validate tag=ci_tag:
    ./scripts/validate.sh {{tag}}

# Multi-platform build + push via Depot CLI. Workstation convenience —
# CI uses depot/build-push-action so it can hand the digest to cosign/attest.
publish tags: prepare
    depot build \
        --project np622krb2x \
        --platform {{publish_plats}} \
        --build-arg ALPINE_VERSION={{alpine_version}} \
        --build-arg TRIVY_VERSION={{trivy_version}} \
        --build-arg BUSYBOX_VERSION={{busybox_version}} \
        $(printf -- '--tag %s ' {{tags}}) \
        --push \
        .

clean:
    rm -rf dist
