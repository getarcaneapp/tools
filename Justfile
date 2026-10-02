set working-directory := './'
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

_default:
    @just --list

_prepare:
    #!/usr/bin/env bash
    set -euo pipefail

    config="build.yaml"
    alpine_version="$(yq -r '.versions.alpine' "$config")"
    trivy_version="$(yq -r '.versions.trivy' "$config")"
    busybox_version="$(yq -r '.versions.busybox' "$config")"
    go_version="$(yq -r '.versions.go' "$config")"
    acfs_version="$(yq -r '.versions.acfs' "$config")"

    mkdir -p dist
    yq -r '.busybox.config[] | . + "=y"' "$config" > dist/busybox.config
    yq -r '.busybox.applets[]' "$config" > dist/applets.txt

    printf '# Runtime Binary Manifest\n\nGenerated from `build.yaml`; run `just _prepare` to regenerate.\n\nFirst-party binaries shipped in the final runtime image.\n\n| Binary | Version | Build toolchain | Source | Checksum | License |\n|---|---|---|---|---|---|\n| ACFS | %s | Go %s | <https://github.com/getarcaneapp/kit/releases/tag/acfs/v%s> | Built from source in-image at the pinned kit tag (module checksums verified via sum.golang.org) | BSD-3-Clause |\n\nThird-party binaries shipped in the final runtime image.\n\n| Binary | Version | Source | Checksum | License |\n|---|---|---|---|---|\n| Trivy | %s | <https://github.com/aquasecurity/trivy/releases/tag/v%s> | [trivy.txt](trivy.txt) | Apache-2.0 |\n| BusyBox | %s | <https://busybox.net/downloads/busybox-%s.tar.bz2> | [busybox.sha256](busybox.sha256) | GPL-2.0-only |\n\nThe ACFS binary is built from source in-image from the pinned kit\nmonorepo tag, with Go module checksums verified via sum.golang.org. The CA certificate bundle is copied from\nAlpine %s during the build and is not treated as a separately versioned\nexecutable binary.\n' \
        "$acfs_version" "$go_version" "$acfs_version" \
        "$trivy_version" "$trivy_version" \
        "$busybox_version" "$busybox_version" \
        "$alpine_version" \
        > checksums/manifest.md

# Build and load the image. Pass buildx options to override tags, platforms, or output.
[positional-arguments]
build *args: _prepare
    #!/usr/bin/env bash
    set -euo pipefail

    build_args=()
    for component in alpine trivy busybox go acfs; do
        version="$(yq -r ".versions.$component" build.yaml)"
        build_args+=(--build-arg "$(printf '%s' "$component" | tr '[:lower:]' '[:upper:]')_VERSION=$version")
    done

    output_arg=--load
    for arg in "$@"; do
        case "$arg" in
            --push|--push=*|--output|--output=*|-o|-o?*|--load|--load=*) output_arg="";;
        esac
    done

    tag="$(yq -r '.image.local_tag' build.yaml)"
    docker buildx build --tag "$tag" "${build_args[@]}" ${output_arg:+"$output_arg"} "$@" .

# Check the built image's runtime contract.
test tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    tag="{{ tag }}"
    ./scripts/validate.sh "${tag:-$(yq -r '.image.local_tag' build.yaml)}"

# Update pinned versions and checksums. Components: alpine, trivy, busybox, acfs, all.
[positional-arguments]
update *components:
    #!/usr/bin/env bash
    set -euo pipefail

    config_file="build.yaml"
    dockerfile="Dockerfile"
    dry_run="${DRY_RUN:-0}"
    update_alpine=0
    update_trivy=0
    update_busybox=0
    update_acfs=0

    if [ "$#" -eq 0 ]; then
        set -- all
    fi

    for component in "$@"; do
        case "$component" in
            all)
                update_alpine=1
                update_trivy=1
                update_busybox=1
                update_acfs=1
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
            acfs)
                update_acfs=1
                ;;
            *)
                printf 'update: unknown component: %s\n' "$component" >&2
                printf 'valid components: all, alpine, trivy, busybox, acfs\n' >&2
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

    if [ "$update_acfs" -eq 1 ]; then
        # acfs lives in the getarcaneapp/kit monorepo; release tags are
        # prefixed acfs/vX.Y.Z. Annotated tags also list a peeled
        # `^{}` entry, so drop those before picking the highest version.
        acfs_tag="$(
            git ls-remote --tags \
                https://github.com/getarcaneapp/kit \
                'refs/tags/acfs/v*' \
            | cut -d/ -f4 | grep -v '\^{}$' | sort -V | tail -n 1
        )"
        acfs_version="${acfs_tag#v}"
        validate_version acfs "$acfs_version" \
            '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'
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
    if [ "$update_acfs" -eq 1 ]; then
        printf '  acfs:    %s -> %s\n' \
            "$(yq -r '.versions.acfs' "$config_file")" "$acfs_version"
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
    if [ "$update_acfs" -eq 1 ]; then
        update_version acfs ACFS_VERSION "$acfs_version"
    fi

    just _prepare
    printf 'Updated selected versions, checksums, and checksums/manifest.md.\n'

# Mirror Trivy databases to GHCR and Docker Hub.
mirror:
    ./scripts/mirror.sh

# Remove generated build inputs.
clean:
    rm -rf dist
