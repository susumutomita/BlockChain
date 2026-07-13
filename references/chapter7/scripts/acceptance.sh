#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$PROJECT_ROOT/../.." && pwd)
ZIG_VERSION=${ZIG_VERSION:-0.14.0}
IMAGE=${BOOK_CODE_IMAGE:-zig-blockchain-book-toolchain:${ZIG_VERSION}}

run_id=$$
network="zig-book-ch7-${run_id}"
server="zig-book-ch7-server-${run_id}"
client="zig-book-ch7-client-${run_id}"
scratch=$(mktemp -d "$REPO_ROOT/.chapter7-acceptance.XXXXXX")

cleanup() {
  docker rm -f "$client" "$server" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "CHAPTER7_TCP_ACCEPTANCE FAIL: $*" >&2
  docker logs "$server" >&2 2>/dev/null || true
  docker logs "$client" >&2 2>/dev/null || true
  exit 1
}

docker build \
  --build-arg "ZIG_VERSION=$ZIG_VERSION" \
  -t "$IMAGE" \
  "$REPO_ROOT" >/dev/null

docker network create "$network" >/dev/null
docker run --rm \
  --user 0:0 \
  --mount "type=bind,src=$PROJECT_ROOT,dst=/work,readonly" \
  --mount "type=bind,src=$scratch,dst=/scratch" \
  --workdir /work \
  "$IMAGE" \
  sh -ec '
    common="--cache-dir /scratch/cache --global-cache-dir /scratch/global --prefix /scratch/out"
    zig build $common test
    zig build $common
  '

docker run -d \
  --name "$server" \
  --network "$network" \
  --user 0:0 \
  --mount "type=bind,src=$scratch,dst=/scratch,readonly" \
  "$IMAGE" \
  /scratch/out/bin/chapter7 --listen 8081 >/dev/null

attempt=0
while [ "$attempt" -lt 20 ]; do
  if docker logs "$server" 2>&1 | grep -Fq 'Listening on 0.0.0.0:8081'; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$attempt" -eq 20 ]; then
  fail "server did not start"
fi

# 信頼できないP2P入力が固定長hex bufferや整数castでprocessを落とさず、
# 接続単位のparse errorとして拒否されることを確認する。
docker run --rm \
  --network "$network" \
  "$IMAGE" \
  sh -ec "
    oversized=\$(awk 'BEGIN { for (i = 0; i < 514; i++) printf \"0\" }')
    printf 'BLOCK:{\"prev_hash\":\"%s\"}\\n' \"\$oversized\" | nc -w 1 $server 8081 || true
    printf 'BLOCK:{\"timestamp\":-1.5}\\n' | nc -w 1 $server 8081 || true
  " >/dev/null 2>&1
sleep 1
if [ "$(docker inspect -f '{{.State.Running}}' "$server")" != true ]; then
  fail "server exited after malformed P2P input"
fi

docker run -d \
  --name "$client" \
  --network "$network" \
  --user 0:0 \
  --mount "type=bind,src=$scratch,dst=/scratch,readonly" \
  "$IMAGE" \
  sh -ec "printf 'hi\\n' | /scratch/out/bin/chapter7 --connect $server:8081" >/dev/null

attempt=0
while [ "$attempt" -lt 30 ]; do
  if docker logs "$server" 2>&1 | grep -Fq 'Added new block index=1'; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$attempt" -eq 30 ]; then
  fail "server did not add the transmitted block"
fi

server_output=$(docker logs "$server" 2>&1)
added=$(printf '%s\n' "$server_output" | grep -Fc 'Added new block index=1')
if [ "$added" -ne 1 ]; then
  fail "expected one added index=1 block, got $added"
fi

echo "CHAPTER7_TCP_ACCEPTANCE PASS"
echo "added_index_1=$added"
echo "CHAPTER7_TAMPER_TEST PASS"
echo "CHAPTER7_MALFORMED_INPUT_REJECTION PASS"
