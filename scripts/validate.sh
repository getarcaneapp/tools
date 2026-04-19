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
    for helper in sh sleep find stat readlink head rm mkdir mv rmdir mktemp tar test; do
      test -x "/bin/${helper}"
    done
    test -x /usr/local/bin/trivy
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
