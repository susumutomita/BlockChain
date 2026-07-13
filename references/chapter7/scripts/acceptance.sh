#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$PROJECT_ROOT/../.." && pwd)
ZIG_VERSION=${ZIG_VERSION:-0.14.0}
IMAGE=${BOOK_CODE_IMAGE:-zig-blockchain-book-toolchain:${ZIG_VERSION}}
DOCKER_USER=${BOOK_DOCKER_USER:-$(id -u):$(id -g)}

run_id=$$
network="zig-book-ch7-${run_id}"
server="zig-book-ch7-server-${run_id}"
client="zig-book-ch7-client-${run_id}"
frame_server="zig-book-ch7-frame-server-${run_id}"
frame_client="zig-book-ch7-frame-client-${run_id}"
scratch=$(mktemp -d "$REPO_ROOT/.chapter7-acceptance.XXXXXX")

cleanup() {
  docker rm -f "$frame_client" "$frame_server" "$client" "$server" >/dev/null 2>&1 || true
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
  docker logs "$frame_server" >&2 2>/dev/null || true
  docker logs "$frame_client" >&2 2>/dev/null || true
  exit 1
}

docker build \
  --build-arg "ZIG_VERSION=$ZIG_VERSION" \
  -t "$IMAGE" \
  "$REPO_ROOT" >/dev/null

docker network create "$network" >/dev/null
docker run --rm \
  --user "$DOCKER_USER" \
  --mount "type=bind,src=$PROJECT_ROOT,dst=/work,readonly" \
  --mount "type=bind,src=$scratch,dst=/scratch" \
  --workdir /work \
  "$IMAGE" \
  sh -ec '
    common="--cache-dir /scratch/cache --global-cache-dir /scratch/global --prefix /scratch/out"
    zig build $common test
    zig build $common
    zig build-exe scripts/tcp_frame_server.zig \
      --cache-dir /scratch/frame-server-cache \
      --global-cache-dir /scratch/global \
      -femit-bin=/scratch/out/bin/chapter7-tcp-frame-server
  '

docker run -d \
  --name "$server" \
  --network "$network" \
  --user "$DOCKER_USER" \
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
  --user "$DOCKER_USER" \
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
  --user "$DOCKER_USER" \
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

# --connect側もTCPのread境界に依存しないことを実通信で検査する。
# 先に受信した正常ブロックのJSONを利用し、送信サーバは
#   1) 最初の1フレームを複数writeへ分割
#   2) 残り2フレームを1回のwriteAllへ結合
# して同じコネクション上で送る。
block_json=$(printf '%s\n' "$server_output" |
  grep -F '[Received complete message] BLOCK:' |
  grep -F '"data":"hi"' |
  tail -n 1 |
  sed 's/^.*\[Received complete message\] BLOCK://')
if [ -z "$block_json" ]; then
  fail "could not extract the valid transmitted block JSON"
fi
printf '%s\n' "$block_json" >"$scratch/block.json"

docker run -d \
  --name "$frame_server" \
  --network "$network" \
  --user "$DOCKER_USER" \
  --mount "type=bind,src=$scratch,dst=/scratch,readonly" \
  "$IMAGE" \
  /scratch/out/bin/chapter7-tcp-frame-server 8082 /scratch/block.json >/dev/null

attempt=0
while [ "$attempt" -lt 20 ]; do
  if docker logs "$frame_server" 2>&1 | grep -Fq 'TCP_FRAME_SERVER_READY port=8082'; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$attempt" -eq 20 ]; then
  fail "framing regression server did not start"
fi

docker run -d \
  --name "$frame_client" \
  --network "$network" \
  --user "$DOCKER_USER" \
  --mount "type=bind,src=$scratch,dst=/scratch,readonly" \
  "$IMAGE" \
  /scratch/out/bin/chapter7 --connect "$frame_server:8082" >/dev/null

frame_client_status=$(docker wait "$frame_client")
if [ "$frame_client_status" -ne 0 ]; then
  fail "framing regression client exited with status $frame_client_status"
fi

frame_server_status=$(docker wait "$frame_server")
if [ "$frame_server_status" -ne 0 ]; then
  fail "framing regression server exited with status $frame_server_status"
fi

frame_server_output=$(docker logs "$frame_server" 2>&1)
if ! printf '%s\n' "$frame_server_output" | grep -Fq 'TCP_SPLIT_FRAME_SENT'; then
  fail "split-frame write did not complete"
fi
if ! printf '%s\n' "$frame_server_output" | grep -Fq 'TCP_COALESCED_FRAMES_SENT'; then
  fail "coalesced-frame write did not complete"
fi

frame_client_output=$(docker logs "$frame_client" 2>&1)
received=$(printf '%s\n' "$frame_client_output" | grep -Fc '[Recv complete] BLOCK:' || true)
client_added=$(printf '%s\n' "$frame_client_output" | grep -Fc 'Added new block index=1' || true)
if [ "$received" -ne 3 ] || [ "$client_added" -ne 3 ]; then
  fail "client reconstructed $received frames and added $client_added blocks; expected 3 and 3"
fi
if printf '%s\n' "$frame_client_output" | grep -Fq 'Unknown msg:'; then
  fail "client treated a TCP fragment as a complete message"
fi

echo "CHAPTER7_TCP_ACCEPTANCE PASS"
echo "added_index_1=$added"
echo "CHAPTER7_TAMPER_TEST PASS"
echo "CHAPTER7_MALFORMED_INPUT_REJECTION PASS"
echo "CHAPTER7_CLIENT_FRAMING PASS: split=1 coalesced=2"
