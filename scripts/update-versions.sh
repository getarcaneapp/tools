#!/bin/sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/build.yaml"
DOCKERFILE="${REPO_ROOT}/Dockerfile"
DRY_RUN=0

update_alpine=0
update_trivy=0
update_busybox=0

usage() {
  cat <<'EOF'
Usage: ./scripts/update-versions.sh [--dry-run] [all|alpine|trivy|busybox ...]

Resolve the latest upstream releases and update build.yaml, Dockerfile defaults,
and binary checksum files. With no component arguments, all components are
updated. Alpine has no local checksum because it is consumed as a container
base image.
EOF
}

if [ "$#" -eq 0 ]; then
  set -- all
fi

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
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
      printf 'update-versions.sh: unknown component: %s\n' "$arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$update_alpine" -eq 0 ] && [ "$update_trivy" -eq 0 ] && \
   [ "$update_busybox" -eq 0 ]; then
  update_alpine=1
  update_trivy=1
  update_busybox=1
fi

for command_name in curl yq awk grep sort sed just; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'update-versions.sh: %s is required\n' "$command_name" >&2
    exit 2
  fi
done

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/arcane-tools-update.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

validate_version() {
  component="$1"
  version="$2"
  pattern="$3"

  if ! printf '%s\n' "$version" | grep -Eq "$pattern"; then
    printf 'update-versions.sh: invalid %s version from upstream: %s\n' \
      "$component" "$version" >&2
    exit 1
  fi
}

if [ "$update_alpine" -eq 1 ]; then
  curl -fsSL https://alpinelinux.org/releases.json \
    -o "${TEMP_DIR}/alpine-releases.json"
  alpine_version="$(
    yq -r '.latest_stable' "${TEMP_DIR}/alpine-releases.json" | \
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
    -o "${TEMP_DIR}/trivy-upstream.txt"

  : > "${TEMP_DIR}/trivy.txt"
  for trivy_arch in 32bit 64bit ARM ARM64 PPC64LE s390x; do
    trivy_file="trivy_${trivy_version}_Linux-${trivy_arch}.tar.gz"
    matches="$(
      grep -E "^[0-9a-f]{64}  ${trivy_file}$" \
        "${TEMP_DIR}/trivy-upstream.txt" || true
    )"
    match_count="$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')"
    if [ "$match_count" -ne 1 ]; then
      printf 'update-versions.sh: expected one checksum for %s, found %s\n' \
        "$trivy_file" "$match_count" >&2
      exit 1
    fi
    printf '%s\n' "$matches" >> "${TEMP_DIR}/trivy.txt"
  done
fi

if [ "$update_busybox" -eq 1 ]; then
  curl -fsSL https://busybox.net/downloads/ -o "${TEMP_DIR}/busybox-index.html"
  busybox_version="$(
    grep -Eo 'busybox-[0-9]+\.[0-9]+\.[0-9]+\.tar\.bz2' \
      "${TEMP_DIR}/busybox-index.html" | \
      sed -e 's/^busybox-//' -e 's/\.tar\.bz2$//' | \
      sort -u -t. -k1,1n -k2,2n -k3,3n | \
      awk 'END { print }'
  )"
  validate_version busybox "$busybox_version" '^[0-9]+\.[0-9]+\.[0-9]+$'

  busybox_file="busybox-${busybox_version}.tar.bz2"
  curl -fsSL \
    "https://busybox.net/downloads/${busybox_file}.sha256" \
    -o "${TEMP_DIR}/busybox.sha256"
  if ! grep -Eq "^[0-9a-f]{64}  ${busybox_file}$" \
    "${TEMP_DIR}/busybox.sha256"; then
    printf 'update-versions.sh: invalid checksum file for %s\n' \
      "$busybox_file" >&2
    exit 1
  fi
fi

printf 'Resolved versions:\n'
if [ "$update_alpine" -eq 1 ]; then
  printf '  alpine:  %s -> %s\n' \
    "$(yq -r '.versions.alpine' "$CONFIG_FILE")" "$alpine_version"
fi
if [ "$update_trivy" -eq 1 ]; then
  printf '  trivy:   %s -> %s\n' \
    "$(yq -r '.versions.trivy' "$CONFIG_FILE")" "$trivy_version"
fi
if [ "$update_busybox" -eq 1 ]; then
  printf '  busybox: %s -> %s\n' \
    "$(yq -r '.versions.busybox' "$CONFIG_FILE")" "$busybox_version"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Dry run; no files changed.\n'
  exit 0
fi

update_version() {
  yaml_key="$1"
  docker_arg="$2"
  version="$3"

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
  ' "$CONFIG_FILE" > "${TEMP_DIR}/build.yaml"
  mv "${TEMP_DIR}/build.yaml" "$CONFIG_FILE"
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
  ' "$DOCKERFILE" > "${TEMP_DIR}/Dockerfile"
  mv "${TEMP_DIR}/Dockerfile" "$DOCKERFILE"
}

if [ "$update_alpine" -eq 1 ]; then
  update_version alpine ALPINE_VERSION "$alpine_version"
fi
if [ "$update_trivy" -eq 1 ]; then
  update_version trivy TRIVY_VERSION "$trivy_version"
  cp "${TEMP_DIR}/trivy.txt" "${REPO_ROOT}/checksums/trivy.txt"
fi
if [ "$update_busybox" -eq 1 ]; then
  update_version busybox BUSYBOX_VERSION "$busybox_version"
  cp "${TEMP_DIR}/busybox.sha256" "${REPO_ROOT}/checksums/busybox.sha256"
fi

cd "$REPO_ROOT"
just manifest
printf 'Updated selected versions, checksums, and checksums/manifest.md.\n'
