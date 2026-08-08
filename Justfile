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

# Mirror Trivy databases to ghcr.io/getarcaneapp. Prereq: oras, docker login to ghcr.io.
mirror:
    ./scripts/mirror.sh

# Dry-run mirror: resolve digests only, no push.
mirror-dry:
    DRY_RUN=1 ./scripts/mirror.sh

# Resolve and update pinned build inputs and binary checksums.
# Components: alpine, trivy, busybox, or all (default).
update *components:
    #!/usr/bin/env bash
    set -euo pipefail

    config_file="build.yaml"
    dockerfile="Dockerfile"
    dry_run="${DRY_RUN:-0}"
    update_alpine=0
    update_trivy=0
    update_busybox=0

    set -- {{ components }}
    if [ "$#" -eq 0 ]; then
        set -- all
    fi

    for component in "$@"; do
        case "$component" in
            all)
                update_alpine=1
                update_trivy=1
                update_busybox=1
                ;;
            alpine)
                update_alpine=1
                ;;
            trivy)
                update_trivy=1
                ;;
            busybox)
                update_busybox=1
                ;;
            *)
                printf 'update: unknown component: %s\n' "$component" >&2
                printf 'valid components: all, alpine, trivy, busybox\n' >&2
                exit 2
                ;;
        esac
    done

    for command_name in curl yq awk grep sort sed just; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            printf 'update: %s is required\n' "$command_name" >&2
            exit 2
        fi
    done

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/arcane-tools-update.XXXXXX")"
    trap 'rm -rf "$temp_dir"' EXIT HUP INT TERM

    validate_version() {
        local component="$1"
        local version="$2"
        local pattern="$3"

        if ! printf '%s\n' "$version" | grep -Eq "$pattern"; then
            printf 'update: invalid %s version from upstream: %s\n' \
                "$component" "$version" >&2
            exit 1
        fi
    }

    if [ "$update_alpine" -eq 1 ]; then
        curl -fsSL https://alpinelinux.org/releases.json \
            -o "${temp_dir}/alpine-releases.json"
        alpine_version="$(
            yq -r '.latest_stable' "${temp_dir}/alpine-releases.json" | \
                sed 's/^v//'
        )"
        validate_version alpine "$alpine_version" '^[0-9]+\.[0-9]+$'
    fi

    if [ "$update_trivy" -eq 1 ]; then
        trivy_release_url="$(
            curl -fsSL -o /dev/null -w '%{url_effective}' \
                https://github.com/aquasecurity/trivy/releases/latest
        )"
        trivy_tag="${trivy_release_url##*/}"
        trivy_version="${trivy_tag#v}"
        validate_version trivy "$trivy_version" \
            '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'

        curl -fsSL \
            "https://github.com/aquasecurity/trivy/releases/download/v${trivy_version}/trivy_${trivy_version}_checksums.txt" \
            -o "${temp_dir}/trivy-upstream.txt"

        : > "${temp_dir}/trivy.txt"
        for trivy_arch in 32bit 64bit ARM ARM64 PPC64LE s390x; do
            trivy_file="trivy_${trivy_version}_Linux-${trivy_arch}.tar.gz"
            matches="$(
                grep -E "^[0-9a-f]{64}  ${trivy_file}$" \
                    "${temp_dir}/trivy-upstream.txt" || true
            )"
            match_count="$(
                printf '%s\n' "$matches" | \
                    awk 'NF { count++ } END { print count + 0 }'
            )"
            if [ "$match_count" -ne 1 ]; then
                printf 'update: expected one checksum for %s, found %s\n' \
                    "$trivy_file" "$match_count" >&2
                exit 1
            fi
            printf '%s\n' "$matches" >> "${temp_dir}/trivy.txt"
        done
    fi

    if [ "$update_busybox" -eq 1 ]; then
        curl -fsSL https://busybox.net/downloads/ \
            -o "${temp_dir}/busybox-index.html"
        busybox_version="$(
            grep -Eo 'busybox-[0-9]+\.[0-9]+\.[0-9]+\.tar\.bz2' \
                "${temp_dir}/busybox-index.html" | \
                sed -e 's/^busybox-//' -e 's/\.tar\.bz2$//' | \
                sort -u -t. -k1,1n -k2,2n -k3,3n | \
                awk 'END { print }'
        )"
        validate_version busybox "$busybox_version" \
            '^[0-9]+\.[0-9]+\.[0-9]+$'

        busybox_file="busybox-${busybox_version}.tar.bz2"
        curl -fsSL \
            "https://busybox.net/downloads/${busybox_file}.sha256" \
            -o "${temp_dir}/busybox.sha256"
        if ! grep -Eq "^[0-9a-f]{64}  ${busybox_file}$" \
            "${temp_dir}/busybox.sha256"; then
            printf 'update: invalid checksum file for %s\n' \
                "$busybox_file" >&2
            exit 1
        fi
    fi

    printf 'Resolved versions:\n'
    if [ "$update_alpine" -eq 1 ]; then
        printf '  alpine:  %s -> %s\n' \
            "$(yq -r '.versions.alpine' "$config_file")" "$alpine_version"
    fi
    if [ "$update_trivy" -eq 1 ]; then
        printf '  trivy:   %s -> %s\n' \
            "$(yq -r '.versions.trivy' "$config_file")" "$trivy_version"
    fi
    if [ "$update_busybox" -eq 1 ]; then
        printf '  busybox: %s -> %s\n' \
            "$(yq -r '.versions.busybox' "$config_file")" "$busybox_version"
    fi

    if [ "$dry_run" = "1" ]; then
        printf 'Dry run; no files changed.\n'
        exit 0
    fi

    update_version() {
        local yaml_key="$1"
        local docker_arg="$2"
        local version="$3"

        awk -v key="$yaml_key" -v value="$version" '
            $0 ~ "^  " key ": " {
                print "  " key ": \"" value "\""
                found = 1
                next
            }
            { print }
            END {
                if (!found) {
                    exit 1
                }
            }
        ' "$config_file" > "${temp_dir}/build.yaml"
        mv "${temp_dir}/build.yaml" "$config_file"
        awk -v key="$docker_arg" -v value="$version" '
            $0 ~ "^ARG " key "=" {
                print "ARG " key "=" value
                found = 1
                next
            }
            { print }
            END {
                if (!found) {
                    exit 1
                }
            }
        ' "$dockerfile" > "${temp_dir}/Dockerfile"
        mv "${temp_dir}/Dockerfile" "$dockerfile"
    }

    if [ "$update_alpine" -eq 1 ]; then
        update_version alpine ALPINE_VERSION "$alpine_version"
    fi
    if [ "$update_trivy" -eq 1 ]; then
        update_version trivy TRIVY_VERSION "$trivy_version"
        cp "${temp_dir}/trivy.txt" checksums/trivy.txt
    fi
    if [ "$update_busybox" -eq 1 ]; then
        update_version busybox BUSYBOX_VERSION "$busybox_version"
        cp "${temp_dir}/busybox.sha256" checksums/busybox.sha256
    fi

    just manifest
    printf 'Updated selected versions, checksums, and checksums/manifest.md.\n'

# Show the latest upstream versions without changing files.
update-dry *components:
    DRY_RUN=1 just update {{ components }}

clean:
    rm -rf dist
