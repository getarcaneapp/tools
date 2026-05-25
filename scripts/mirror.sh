#!/bin/sh
# Mirror Trivy databases from upstream to ghcr.io/getarcaneapp.
# Reads mirror config from build.yaml (mirrors: block).
#
# Prerequisites: oras, yq (v4+), docker login to ghcr.io
#
# Usage:
#   ./scripts/mirror.sh              # mirror all three DBs
#   DRY_RUN=1 ./scripts/mirror.sh   # resolve digests only, no push

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/../build.yaml}"
DRY_RUN="${DRY_RUN:-0}"

if ! command -v oras >/dev/null 2>&1; then
  echo "mirror.sh: oras is required (https://oras.land)" >&2
  exit 2
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "mirror.sh: yq is required (github.com/mikefarah/yq v4+)" >&2
  exit 2
fi

failed=0

yq -r '.mirrors[] | .source + " " + .target + " " + .tag' "$CONFIG_FILE" | \
while IFS=' ' read -r source target tag; do
  src="${source}:${tag}"
  dst="${target}:${tag}"

  printf '==> %s -> %s\n' "${src}" "${dst}"

  upstream_digest="$(oras resolve "${src}")"
  printf '    upstream: %s\n' "${upstream_digest}"

  if existing="$(oras resolve "${dst}" 2>/dev/null)"; then
    printf '    mirror:   %s\n' "${existing}"
    if [ "${existing}" = "${upstream_digest}" ]; then
      printf '    result:   already in sync, skipping\n'
      continue
    fi
  else
    printf '    mirror:   (does not exist yet)\n'
  fi

  if [ "${DRY_RUN}" = "1" ]; then
    printf '    result:   dry-run, skipping copy\n'
    continue
  fi

  oras copy "${src}" "${dst}"
  mirrored="$(oras resolve "${dst}")"
  if [ "${mirrored}" != "${upstream_digest}" ]; then
    printf '    ERROR: mirrored digest %s != upstream %s\n' "${mirrored}" "${upstream_digest}" >&2
    failed=1
    continue
  fi

  printf '    result:   pushed %s\n' "${mirrored}"
done

if [ "${failed}" -ne 0 ]; then
  echo "mirror.sh: one or more mirrors failed" >&2
  exit 1
fi
