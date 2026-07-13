#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZIG_VERSION=${ZIG_VERSION:-0.14.0}
RUNNER=${BOOK_CODE_RUNNER:-auto}
IMAGE=${BOOK_CODE_IMAGE:-zig-blockchain-book-toolchain:${ZIG_VERSION}}

all_projects='.
references/chapter2
references/chapter3/step1
references/chapter3/step2
references/chapter3/step3
references/chapter3/step4
references/chapter3/step4-2
references/chapter3/step5
references/chapter4/step1
references/chapter4/step2
references/chapter4/step3
references/chapter5
references/chapter6/step1/nodeA
references/chapter6/step1/nodeB
references/chapter6/step2/nodeA
references/chapter7
references/chapter8
references/chapter9
references/EVMchapter'

if [ "$#" -gt 0 ]; then
    projects="$*"
else
    projects=$all_projects
fi

if [ "$RUNNER" = auto ]; then
    if [ "$(uname -s)" = Darwin ]; then
        RUNNER=docker
    elif command -v zig >/dev/null 2>&1; then
        RUNNER=local
    else
        RUNNER=docker
    fi
fi

if [ "$RUNNER" = docker ]; then
    docker build \
        --build-arg "ZIG_VERSION=${ZIG_VERSION}" \
        -t "$IMAGE" \
        "$ROOT"
elif [ "$RUNNER" != local ]; then
    echo "BOOK_CODE_RUNNER must be auto, local, or docker" >&2
    exit 2
fi

verify_local() {
    project=$1
    (
        cd "$ROOT/$project"
        zig build
        help_file="${TMPDIR:-/tmp}/zig-book-help-$$"
        trap 'rm -f "$help_file"' EXIT
        zig build --help >"$help_file"
        if grep -q '^  test ' "$help_file"; then
            zig build test
        fi
    )
}

verify_docker() {
    project=$1
    docker run --rm \
        --mount "type=bind,src=$ROOT/$project,dst=/work,readonly" \
        --workdir /work \
        "$IMAGE" \
        sh -ec '
            common="--prefix /tmp/zig-out --cache-dir /tmp/zig-cache --global-cache-dir /tmp/zig-global-cache"
            zig build $common
            zig build $common --help >/tmp/zig-build-help
            if grep -q "^  test " /tmp/zig-build-help; then
                zig build $common test
            fi
        '
}

for project in $projects; do
    if [ ! -f "$ROOT/$project/build.zig" ]; then
        echo "missing build.zig: $project" >&2
        exit 1
    fi

    echo "==> $project"
    if [ "$RUNNER" = local ]; then
        verify_local "$project"
    else
        verify_docker "$project"
    fi
    echo "PASS $project"
done
