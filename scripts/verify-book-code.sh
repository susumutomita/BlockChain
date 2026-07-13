#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZIG_VERSION=${ZIG_VERSION:-0.14.0}
RUNNER=${BOOK_CODE_RUNNER:-auto}
IMAGE=${BOOK_CODE_IMAGE:-zig-blockchain-book-toolchain:${ZIG_VERSION}}
CACHE_ROOT=${BOOK_CODE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zig-blockchain-book/verify}
DOCKER_USER=${BOOK_DOCKER_USER:-$(id -u):$(id -g)}

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
references/chapter10
references/chapter11
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
    mkdir -p "$CACHE_ROOT"
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
    cache_key=$(printf '%s' "$project" | tr '/.' '__')
    docker run --rm \
        --user "$DOCKER_USER" \
        --mount "type=bind,src=$ROOT/$project,dst=/work,readonly" \
        --mount "type=bind,src=$CACHE_ROOT,dst=/book-cache" \
        --env "BOOK_CACHE_KEY=$cache_key" \
        --workdir /work \
        "$IMAGE" \
        sh -ec '
            local_cache="/book-cache/local/$BOOK_CACHE_KEY"
            out_dir="/book-cache/out/$BOOK_CACHE_KEY"
            global_cache="/book-cache/global"
            mkdir -p "$local_cache" "$out_dir" "$global_cache"
            common="--prefix $out_dir --cache-dir $local_cache --global-cache-dir $global_cache"
            zig build $common
            zig build $common --help >"/book-cache/help-$BOOK_CACHE_KEY"
            if grep -q "^  test " "/book-cache/help-$BOOK_CACHE_KEY"; then
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
