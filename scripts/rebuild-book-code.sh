#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZIG_VERSION=${ZIG_VERSION:-0.14.0}
RUNNER=${BOOK_REBUILD_RUNNER:-auto}
IMAGE=${BOOK_REBUILD_IMAGE:-zig-blockchain-book-rebuild:${ZIG_VERSION}}
# Keep reconstructed trees under the checkout by default. Docker Desktop and
# Colima both share checkout paths, while the host's system temp directory is
# not necessarily bind-mountable into their Linux VM.
TMP_PARENT=${BOOK_REBUILD_TMPDIR:-$ROOT}
TMP_ROOT=$(mktemp -d "$TMP_PARENT/.zig-book-rebuild.XXXXXX")
CHAPTER11="$TMP_ROOT/chapter11"
CHAPTER12="$TMP_ROOT/chapter12"
GLOBAL_CACHE="$TMP_ROOT/cache/global"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "BOOK_REBUILD FAIL: $*" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required command is unavailable: $1"
  fi
}

apply_companion_patch() {
  project=$1
  patch_file=$2
  label=$3

  if [ ! -f "$patch_file" ]; then
    fail "$label companion patch is missing: $patch_file"
  fi

  # The reconstructed directory lives below the main checkout. Give it its own
  # temporary Git boundary so `git apply` cannot discover the parent worktree
  # and ignore paths that are outside the current subdirectory.
  git -C "$project" init -q
  git -C "$project" apply --check "$patch_file"
  git -C "$project" apply "$patch_file"
  rm -rf "$project/.git"
  echo "$label PATCH_APPLY PASS"
}

assert_same_tree() {
  rebuilt=$1
  expected=$2
  label=$3
  report="$TMP_ROOT/${label}-tree.diff"

  if ! diff -qr "$expected" "$rebuilt" >"$report"; then
    cat "$report" >&2
    fail "$label rebuilt tree does not match $expected"
  fi
  if ! git diff \
    --no-index \
    --no-ext-diff \
    --exit-code \
    -- "$expected" "$rebuilt" >"$report"; then
    cat "$report" >&2
    fail "$label rebuilt file content or modes do not match $expected"
  fi
  echo "$label TREE_MATCH PASS"
}

verify_zig_project() {
  project=$1
  label=$2
  cache="$TMP_ROOT/cache/$label"
  prefix="$TMP_ROOT/out/$label"

  mkdir -p "$cache" "$prefix" "$GLOBAL_CACHE"
  if [ "$RUNNER" = local ]; then
    (
      cd "$project"
      zig fmt --check build.zig src
      zig build \
        --cache-dir "$cache" \
        --global-cache-dir "$GLOBAL_CACHE" \
        --prefix "$prefix" \
        --summary all
      zig build test \
        --cache-dir "$cache" \
        --global-cache-dir "$GLOBAL_CACHE" \
        --prefix "$prefix" \
        --summary all
    )
  else
    docker run --rm \
      --user 0:0 \
      --mount "type=bind,src=$project,dst=/work,readonly" \
      --mount "type=bind,src=$cache,dst=/cache" \
      --mount "type=bind,src=$GLOBAL_CACHE,dst=/global-cache" \
      --mount "type=bind,src=$prefix,dst=/out" \
      --workdir /work \
      "$IMAGE" \
      sh -ec '
        zig fmt --check build.zig src
        zig build --cache-dir /cache --global-cache-dir /global-cache --prefix /out --summary all
        zig build test --cache-dir /cache --global-cache-dir /global-cache --prefix /out --summary all
      '
  fi
  echo "$label ZIG_BUILD_TEST PASS"
}

require_command git
require_command diff

case "$RUNNER" in
  auto)
    if command -v zig >/dev/null 2>&1; then
      RUNNER=local
    elif command -v docker >/dev/null 2>&1; then
      RUNNER=docker
    else
      fail "neither Zig nor Docker is available"
    fi
    ;;
  local)
    require_command zig
    ;;
  docker)
    require_command docker
    ;;
  *)
    fail "BOOK_REBUILD_RUNNER must be auto, local, or docker (got: $RUNNER)"
    ;;
esac

if [ "$RUNNER" = docker ]; then
  docker build \
    --build-arg "ZIG_VERSION=$ZIG_VERSION" \
    -t "$IMAGE" \
    "$ROOT"
  actual_zig_version=$(docker run --rm "$IMAGE" zig version)
else
  actual_zig_version=$(zig version)
fi
if [ "$actual_zig_version" != "$ZIG_VERSION" ]; then
  fail "expected Zig $ZIG_VERSION, got $actual_zig_version"
fi
echo "ZIG_VERSION PASS: $actual_zig_version (runner=$RUNNER)"

echo "[1/5] Rebuilding chapter 11 from chapter 8 plus chapter 10 EVM files"
mkdir -p "$CHAPTER11"
cp -R "$ROOT/references/chapter8/." "$CHAPTER11/"
cp "$ROOT/references/chapter10/src/evm.zig" "$CHAPTER11/src/evm.zig"
cp "$ROOT/references/chapter10/src/evm_types.zig" "$CHAPTER11/src/evm_types.zig"
apply_companion_patch \
  "$CHAPTER11" \
  "$ROOT/references/book-patches/chapter11.patch" \
  CHAPTER11

echo "[2/5] Proving the rebuilt chapter 11 tree matches its checkpoint"
assert_same_tree "$CHAPTER11" "$ROOT/references/chapter11" chapter11

echo "[3/5] Rebuilding chapter 12 from chapter 11"
mkdir -p "$CHAPTER12"
cp -R "$CHAPTER11/." "$CHAPTER12/"
apply_companion_patch \
  "$CHAPTER12" \
  "$ROOT/references/book-patches/chapter12.patch" \
  CHAPTER12
assert_same_tree "$CHAPTER12" "$ROOT/references/EVMchapter" chapter12

echo "[4/5] Formatting, building, and testing both reconstructed checkpoints"
verify_zig_project "$CHAPTER11" chapter11
verify_zig_project "$CHAPTER12" chapter12

echo "[5/5] Optional reconstructed chapter 12 network acceptance"
if [ "${BOOK_REBUILD_ACCEPTANCE:-0}" = 1 ]; then
  require_command docker
  acceptance_tmp="$TMP_ROOT/acceptance-tmp"
  mkdir -p "$acceptance_tmp"
  TMPDIR="$acceptance_tmp" sh "$CHAPTER12/scripts/acceptance.sh" "$CHAPTER12"
  echo "CHAPTER12_REBUILT_ACCEPTANCE PASS"
else
  echo "CHAPTER12_REBUILT_ACCEPTANCE SKIP (set BOOK_REBUILD_ACCEPTANCE=1 to run)"
fi

echo "BOOK_REBUILD PASS"
