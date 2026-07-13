#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$PROJECT_ROOT/../../../.." && pwd)
STEP1_NODE_A="$REPO_ROOT/references/chapter6/step1/nodeA"
STEP1_NODE_B="$REPO_ROOT/references/chapter6/step1/nodeB"
ZIG_VERSION=${ZIG_VERSION:-0.14.0}
IMAGE=${BOOK_CODE_IMAGE:-zig-blockchain-book-toolchain:${ZIG_VERSION}}
DOCKER_USER=${BOOK_DOCKER_USER:-$(id -u):$(id -g)}

run_id=$$
network="zig-book-ch6-${run_id}"
server="zig-book-ch6-server-${run_id}"
scratch=$(mktemp -d "$REPO_ROOT/.chapter6-acceptance.XXXXXX")

cleanup() {
  docker rm -f "$server" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "CHAPTER6_TCP_ACCEPTANCE FAIL: $*" >&2
  docker logs "$server" >&2 2>/dev/null || true
  exit 1
}

docker build \
  --build-arg "ZIG_VERSION=$ZIG_VERSION" \
  -t "$IMAGE" \
  "$REPO_ROOT" >/dev/null

step1_output=$(docker run --rm \
  --user "$DOCKER_USER" \
  --mount "type=bind,src=$STEP1_NODE_A,dst=/nodeA,readonly" \
  --mount "type=bind,src=$STEP1_NODE_B,dst=/nodeB,readonly" \
  --mount "type=bind,src=$scratch,dst=/scratch" \
  "$IMAGE" \
  sh -ec '
    cd /nodeA
    zig build --cache-dir /scratch/step1-a-cache --global-cache-dir /scratch/global --prefix /scratch/step1-a
    cd /nodeB
    zig build --cache-dir /scratch/step1-b-cache --global-cache-dir /scratch/global --prefix /scratch/step1-b
    /scratch/step1-a/bin/nodeA &
    server_pid=$!
    sleep 1
    /scratch/step1-b/bin/nodeB
    wait "$server_pid"
  ' 2>&1) || fail "step 1 one-way TCP processes failed"

if ! printf '%s\n' "$step1_output" | grep -Fq 'ノードA: メッセージ内容: Hello from NodeB'; then
  printf '%s\n' "$step1_output" >&2
  fail "step 1 server did not receive Hello from NodeB"
fi
echo "CHAPTER6_STEP1_ACCEPTANCE PASS"

docker network create "$network" >/dev/null
docker run --rm \
  --user "$DOCKER_USER" \
  --mount "type=bind,src=$PROJECT_ROOT,dst=/work,readonly" \
  --mount "type=bind,src=$scratch,dst=/scratch" \
  --workdir /work \
  "$IMAGE" \
  zig build \
  --cache-dir /scratch/cache \
  --global-cache-dir /scratch/global \
  --prefix /scratch/out

docker run -d \
  --name "$server" \
  --network "$network" \
  --user "$DOCKER_USER" \
  --mount "type=bind,src=$scratch,dst=/scratch,readonly" \
  "$IMAGE" \
  /scratch/out/bin/nodeA --listen 8080 >/dev/null

attempt=0
while [ "$attempt" -lt 20 ]; do
  if docker logs "$server" 2>&1 | grep -Fq 'Listening on port 8080'; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$attempt" -eq 20 ]; then
  fail "server did not start"
fi

# The chapter 6 client intentionally accepts an IP address, not a hostname.
server_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$server")
if [ -z "$server_ip" ]; then
  fail "could not resolve the server container IP"
fi

client_output=$(docker run --rm \
  --network "$network" \
  --user "$DOCKER_USER" \
  --mount "type=bind,src=$scratch,dst=/scratch,readonly" \
  "$IMAGE" \
  sh -ec "printf 'HELLO A\\n' | /scratch/out/bin/nodeA --connect $server_ip:8080" \
  2>&1) || fail "client process failed"
server_output=$(docker logs "$server" 2>&1)

if ! printf '%s\n' "$server_output" | grep -F '[Received from' | grep -Fq 'HELLO A'; then
  fail "server did not receive HELLO A"
fi
if ! printf '%s\n' "$client_output" | grep -Fq 'ACK:HELLO A'; then
  printf '%s\n' "$client_output" >&2
  fail "client did not receive ACK:HELLO A"
fi

echo "CHAPTER6_TCP_ACCEPTANCE PASS"
echo "request=HELLO A"
echo "response=ACK:HELLO A"
