#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

ZIG_BOOK_CACHE_DIR=${ZIG_BOOK_CACHE_DIR:-"$HOME/.cache/zig-blockchain-book/chapter8"}
export ZIG_BOOK_CACHE_DIR
mkdir -p "$ZIG_BOOK_CACHE_DIR"
chmod 0777 "$ZIG_BOOK_CACHE_DIR"

tmp_dir=$(mktemp -d)
cleanup() {
  docker compose down --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

query_chain() {
  service=$1
  output=$2
  docker compose exec -T "$service" sh -c \
    "printf 'GET_CHAIN\\n' | nc -w 2 127.0.0.1 3000" \
    >"$output" 2>/dev/null || true
}

docker compose up --build -d

attempt=0
while [ "$attempt" -lt 45 ]; do
  query_chain node1 "$tmp_dir/node1.chain"
  query_chain node2 "$tmp_dir/node2.chain"
  query_chain node3 "$tmp_dir/node3.chain"

  node1_blocks=$(grep -c '^BLOCK:' "$tmp_dir/node1.chain" || true)
  node2_blocks=$(grep -c '^BLOCK:' "$tmp_dir/node2.chain" || true)
  node3_blocks=$(grep -c '^BLOCK:' "$tmp_dir/node3.chain" || true)

  if [ "$node1_blocks" -eq 2 ] &&
    [ "$node2_blocks" -eq 2 ] &&
    [ "$node3_blocks" -eq 2 ] &&
    cmp -s "$tmp_dir/node1.chain" "$tmp_dir/node2.chain" &&
    cmp -s "$tmp_dir/node1.chain" "$tmp_dir/node3.chain"; then
    break
  fi

  attempt=$((attempt + 1))
  sleep 1
done

if [ "$attempt" -eq 45 ]; then
  echo "P2P_ACCEPTANCE FAIL: three chains did not converge" >&2
  docker compose logs --no-color >&2
  exit 1
fi

for service in node1 node2 node3; do
  added=$(docker compose logs --no-color "$service" | grep -c 'Added new block index=2' || true)
  if [ "$added" -ne 1 ]; then
    echo "P2P_ACCEPTANCE FAIL: $service added index=2 $added times" >&2
    docker compose logs --no-color "$service" >&2
    exit 1
  fi
done

if ! docker compose logs --no-color | grep -q 'BLOCK_REJECTED reason=duplicate'; then
  echo "P2P_ACCEPTANCE FAIL: triangular gossip did not exercise duplicate rejection" >&2
  docker compose logs --no-color >&2
  exit 1
fi

cp "$tmp_dir/node1.chain" "$tmp_dir/before-invalid.chain"

docker compose exec -T node1 sh -ec '
  oversized=$(awk '\''BEGIN { for (i = 0; i < 514; i++) printf "0" }'\'')
  printf '\''BLOCK:{"prev_hash":"%s"}\n'\'' "$oversized" | nc -w 1 127.0.0.1 3000 || true
  printf '\''BLOCK:{"timestamp":-1.5}\n'\'' | nc -w 1 127.0.0.1 3000 || true
' >/dev/null 2>&1
sleep 1
if ! docker compose ps --status running --services | grep -Fxq node1; then
  echo "P2P_ACCEPTANCE FAIL: node1 exited after malformed P2P input" >&2
  docker compose logs --no-color node1 >&2
  exit 1
fi
query_chain node1 "$tmp_dir/after-malformed.chain"
if ! cmp -s "$tmp_dir/before-invalid.chain" "$tmp_dir/after-malformed.chain"; then
  echo "P2P_ACCEPTANCE FAIL: malformed P2P input changed node1 chain" >&2
  docker compose logs --no-color node1 >&2
  exit 1
fi

tampered=$(tail -n 1 "$tmp_dir/node1.chain" | sed 's/"data":"gossip"/"data":"tampered"/')
if [ "$tampered" = "$(tail -n 1 "$tmp_dir/node1.chain")" ]; then
  echo "P2P_ACCEPTANCE FAIL: could not construct the tampered block" >&2
  exit 1
fi

docker compose exec -T node1 sh -c \
  "printf '%s\\n' '$tampered' | nc -w 1 127.0.0.1 3000" \
  >/dev/null 2>&1 || true
sleep 1
query_chain node1 "$tmp_dir/after-invalid.chain"

if ! cmp -s "$tmp_dir/before-invalid.chain" "$tmp_dir/after-invalid.chain"; then
  echo "P2P_ACCEPTANCE FAIL: tampered block changed node1 chain" >&2
  docker compose logs --no-color node1 >&2
  exit 1
fi

if ! docker compose logs --no-color node1 | grep -q 'BLOCK_REJECTED reason=invalid_pow'; then
  echo "P2P_ACCEPTANCE FAIL: node1 did not report invalid PoW/hash" >&2
  docker compose logs --no-color node1 >&2
  exit 1
fi

echo "P2P_ACCEPTANCE PASS"
echo "P2P_MALFORMED_INPUT_REJECTION PASS"
echo "height=2"
grep '^BLOCK:' "$tmp_dir/node1.chain" | sed -n 's/.*"hash":"\([0-9a-f]*\)".*/hash=\1/p'
