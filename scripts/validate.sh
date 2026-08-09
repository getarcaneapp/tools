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
    version_response="$(head -c 512 /tmp/acfs-version.json)"
    case "$version_response" in
      *\"protocol\":2*) ;;
      *)
        echo "acfs does not advertise protocol 2" >&2
        exit 1
        ;;
    esac

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

    acfs walk --root "$fixture" --path / --max-entries 1 \
      > /tmp/acfs-bounded-walk.ndjson
    bounded_walk="$(head -c 2048 /tmp/acfs-bounded-walk.ndjson)"
    case "$bounded_walk" in
      *\"end\":true*\"truncated\":true*\"count\":1*\"version\":2*) ;;
      *)
        echo "acfs bounded walk did not emit its truncation trailer" >&2
        exit 1
        ;;
    esac

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
    write_error="$(head -c 2048 /tmp/acfs-error.stderr)"
    case "$write_error" in
      *\"code\":\"size_mismatch\"*\"version\":2*) ;;
      *)
        echo "acfs did not emit a structured protocol 2 error" >&2
        exit 1
        ;;
    esac
    test "$(head -c 7 "$fixture/nested/file.txt")" = payload

    staging=/tmp/acfs-staging
    mkdir -p "$staging"
    printf batch > "$staging/change-0"
    printf "%s" \
      "{\"changes\":[{\"operation\":\"create_file\",\"path\":\"/nested/applied.txt\",\"stagedName\":\"change-0\",\"size\":5}],\"version\":2}" \
      > "$staging/manifest.json"
    acfs apply --root "$fixture" --staging "$staging" \
      --manifest manifest.json > /tmp/acfs-apply.json
    test "$(head -c 5 "$fixture/nested/applied.txt")" = batch
    apply_response="$(head -c 256 /tmp/acfs-apply.json)"
    case "$apply_response" in
      *\"applied\":1*\"version\":2*) ;;
      *)
        echo "acfs apply did not report the applied change" >&2
        exit 1
        ;;
    esac

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
