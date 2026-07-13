#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_DIR="$ROOT/references/book-patches"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zig-book-patches.XXXXXX")

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_file() {
  if [ ! -f "$1" ]; then
    echo "missing required file: $1" >&2
    exit 1
  fi
}

init_baseline() {
  work_tree=$1
  git -C "$work_tree" init -q
  git -C "$work_tree" config user.name book-patch-generator
  git -C "$work_tree" config user.email book-patch-generator@example.invalid
  git -C "$work_tree" add -A
  git -C "$work_tree" -c commit.gpgsign=false commit -qm baseline
}

write_patch() {
  work_tree=$1
  target_tree=$2
  output_file=$3

  # Keep the temporary repository metadata while replacing every baseline file
  # with the checked-in chapter target.
  rsync -a --delete --exclude=.git "$target_tree/" "$work_tree/"
  git -C "$work_tree" add -A
  git -C "$work_tree" diff \
    --cached \
    --binary \
    --full-index \
    --no-renames \
    --src-prefix=a/ \
    --dst-prefix=b/ \
    --output="$output_file"
}

for path in \
  "$ROOT/references/chapter8" \
  "$ROOT/references/chapter10/src/evm.zig" \
  "$ROOT/references/chapter10/src/evm_types.zig" \
  "$ROOT/references/chapter11" \
  "$ROOT/references/EVMchapter"
do
  if [ ! -e "$path" ]; then
    echo "missing required path: $path" >&2
    exit 1
  fi
done

mkdir -p "$OUTPUT_DIR"

chapter11_work="$TMP_ROOT/chapter11"
mkdir -p "$chapter11_work"
cp -R "$ROOT/references/chapter8/." "$chapter11_work/"
cp "$ROOT/references/chapter10/src/evm.zig" "$chapter11_work/src/evm.zig"
cp "$ROOT/references/chapter10/src/evm_types.zig" "$chapter11_work/src/evm_types.zig"
init_baseline "$chapter11_work"
write_patch \
  "$chapter11_work" \
  "$ROOT/references/chapter11" \
  "$OUTPUT_DIR/chapter11.patch"

chapter12_work="$TMP_ROOT/chapter12"
mkdir -p "$chapter12_work"
cp -R "$ROOT/references/chapter11/." "$chapter12_work/"
init_baseline "$chapter12_work"
write_patch \
  "$chapter12_work" \
  "$ROOT/references/EVMchapter" \
  "$OUTPUT_DIR/chapter12.patch"

require_file "$OUTPUT_DIR/chapter11.patch"
require_file "$OUTPUT_DIR/chapter12.patch"

echo "BOOK_PATCH_GENERATION PASS"
echo "  $OUTPUT_DIR/chapter11.patch"
echo "  $OUTPUT_DIR/chapter12.patch"
