#!/bin/sh

set -eu

IMAGE_REF="${1:-arcane-toolbox:dev}"
CONFIG_FILE="${CONFIG_FILE:-build.yaml}"

if ! command -v yq >/dev/null 2>&1; then
  echo "validate.sh: yq is required (github.com/mikefarah/yq v4+)" >&2
  exit 2
fi

HELPERS="$(yq -r '.busybox.applets[]' "$CONFIG_FILE" | tr '\n' ' ')"
export HELPERS

run_check() {
  check_name="$1"
  shift

  printf '==> %s\n' "$check_name"
  "$@"
}

run_check "required helper commands are on PATH" \
  docker run --rm -e HELPERS "$IMAGE_REF" sh -ceu '
    for helper in $HELPERS; do
      test -x "/bin/${helper}"
    done
    test -x /usr/local/bin/trivy
    test -x /usr/local/bin/acfs
  '

run_check "no extra helper commands slipped into the runtime image" \
  docker run --rm "$IMAGE_REF" sh -ceu '
    test ! -e /bin/ln
    if ln -s /bin/sh /tmp/link 2>/dev/null; then
      echo "unexpected ln command is available" >&2
      exit 1
    fi
    if find /tmp -type f >/dev/null 2>&1; then
      echo "unexpected find -type support is available" >&2
      exit 1
    fi
  '

run_check "trivy is installed at the stable path" \
  docker run --rm "$IMAGE_REF" sh -ceu '
    test -x /usr/local/bin/trivy
    /usr/local/bin/trivy --version >/dev/null
    trivy --version >/dev/null
  '

run_check "acfs root-confined protocol and mutation workflow succeeds" \
  docker run --rm "$IMAGE_REF" sh -ceu '
    fixture=/tmp/acfs-fixture
    mkdir -p "$fixture"

    acfs version > /tmp/acfs-version.json
    test "$(head -c 12 /tmp/acfs-version.json)" = "{\"version\":\""

    acfs mkdir --root "$fixture" --path /nested --mode 0750
    printf payload | acfs write \
      --root "$fixture" --path /nested/file.txt --size 7 --mode 0640
    test "$(head -c 7 "$fixture/nested/file.txt")" = payload

    acfs list --root "$fixture" --path /nested > /tmp/acfs-list.json
    test "$(head -c 13 /tmp/acfs-list.json)" = "{\"entries\":[{"

    acfs stat --root "$fixture" --path /nested/file.txt > /tmp/acfs-stat.json
    test "$(head -c 10 /tmp/acfs-stat.json)" = "{\"entry\":{"

    acfs walk --root "$fixture" --path / > /tmp/acfs-walk.ndjson
    test "$(head -c 10 /tmp/acfs-walk.ndjson)" = "{\"entry\":{"

    acfs read --root "$fixture" --path /nested/file.txt --limit 4 \
      > /tmp/acfs-read.bin
    test "$(stat -c %s /tmp/acfs-read.bin)" = 20
    test "$(head -c 4 /tmp/acfs-read.bin)" = ARCW

    if printf excess | acfs write \
      --root "$fixture" --path /nested/file.txt --size 3 \
      >/tmp/acfs-error.stdout 2>/tmp/acfs-error.stderr; then
      echo "acfs accepted excess write input" >&2
      exit 1
    fi
    test ! -s /tmp/acfs-error.stdout
    test -s /tmp/acfs-error.stderr
    test "$(head -c 7 "$fixture/nested/file.txt")" = payload

    acfs remove --root "$fixture" --path /nested
    test ! -e "$fixture/nested"
  '

run_check "gzip-compressed tar workflow succeeds" \
  docker run --rm "$IMAGE_REF" sh -ceu '
    mkdir -p /tmp/src /tmp/dst
    printf hello >/tmp/src/file.txt
    tar -C /tmp/src -czf /tmp/test.tar.gz .
    tar -tzf /tmp/test.tar.gz >/dev/null
    tar -C /tmp/dst -xzf /tmp/test.tar.gz
    test "$(head -c 5 /tmp/dst/file.txt)" = hello
  '

run_check "file metadata helpers behave as expected" \
  docker run --rm "$IMAGE_REF" sh -ceu '
    mkdir -p /tmp/tree
    printf data >/tmp/tree/file.txt
    find /tmp/tree -maxdepth 1 >/dev/null
    stat -c %s /tmp/tree/file.txt >/dev/null
    test "$(readlink /bin/sh)" = /bin/busybox
    test "$(head -c 4 /tmp/tree/file.txt)" = data
  '

run_check "tmp and cache paths are writable" \
  docker run --rm "$IMAGE_REF" sh -ceu '
    test -w /tmp
    mkdir -p /root/.cache
    test -w /root/.cache
  '

if [ "${VALIDATE_DOCKER_SOCKET:-0}" = "1" ]; then
  run_check "docker socket trivy scan" \
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      "$IMAGE_REF" \
      trivy image --cache-dir /root/.cache docker.io/library/alpine:3.22 >/dev/null
fi

printf 'All validation checks passed for %s\n' "$IMAGE_REF"
