#!/bin/sh

set -eu

IMAGE_REF="${1:-arcane-toolbox:dev}"

run_check() {
  check_name="$1"
  shift

  printf '==> %s\n' "$check_name"
  "$@"
}

run_check "required helper commands are on PATH" \
  docker run --rm "$IMAGE_REF" sh -ceu '
    command -v sh sleep find stat readlink head rm mkdir mv rmdir mktemp tar test >/dev/null
  '

run_check "trivy is installed at the stable path" \
  docker run --rm "$IMAGE_REF" sh -ceu '
    test -x /usr/local/bin/trivy
    /usr/local/bin/trivy --version >/dev/null
    trivy --version >/dev/null
  '

run_check "tar create and extract workflow succeeds" \
  docker run --rm "$IMAGE_REF" sh -ceu '
    mkdir -p /tmp/src /tmp/dst
    printf hello >/tmp/src/file.txt
    tar -C /tmp/src -cf /tmp/test.tar .
    tar -C /tmp/dst -xf /tmp/test.tar
    test "$(head -n 1 /tmp/dst/file.txt)" = hello
  '

run_check "file metadata and symlink helpers behave as expected" \
  docker run --rm "$IMAGE_REF" sh -ceu '
    mkdir -p /tmp/tree
    printf data >/tmp/tree/file.txt
    /bin/busybox ln -s /tmp/tree/file.txt /tmp/tree/link.txt
    find /tmp/tree -maxdepth 1 >/dev/null
    stat /tmp/tree/file.txt >/dev/null
    test "$(readlink /tmp/tree/link.txt)" = /tmp/tree/file.txt
    test "$(head -n 1 /tmp/tree/file.txt)" = data
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
