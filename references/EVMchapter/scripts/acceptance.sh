#!/bin/sh
set -eu

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [project-root]" >&2
  exit 2
fi

if [ "$#" -eq 1 ]; then
  project_root=$1
else
  project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fi
cd "$project_root"

ZIG_VERSION=0.14.0
SOLC_VERSION=0.8.24
SOLC_FULL_VERSION=0.8.24+commit.e11b9ed9.Linux.g++
SOLC_IMAGE=ethereum/solc@sha256:e56ef5e376ae846f06b919d7ca4ed0c271f7fb0900daa6c660d53451f5bfd9db
CONTRACT_ADDRESS=0x000000000000000000000000000000000000abcd
SENDER_ADDRESS=0x000000000000000000000000000000000000dead
DOCKER_USER=${BOOK_DOCKER_USER:-$(id -u):$(id -g)}

run_id=$$
zig_image="zig-blockchain-evm-acceptance:${ZIG_VERSION}-${run_id}"
one_node="zig-book-evm-one-${run_id}"
deploy_node="zig-book-evm-deploy-${run_id}"
call_node="zig-book-evm-call-${run_id}"
network="zig-book-evm-net-${run_id}"
# Keep bind-mounted build output under the checkout by default. Docker Desktop
# and Colima can expose the host's system temp directory as root-owned inside
# the VM, which prevents a host-UID container from creating Zig caches there.
SCRATCH_PARENT=${BOOK_ACCEPTANCE_TMPDIR:-$PWD}
scratch=$(mktemp -d "$SCRATCH_PARENT/.evm-acceptance.XXXXXX")

cleanup() {
  docker unpause "$deploy_node" >/dev/null 2>&1 || true
  docker rm -f "$one_node" "$deploy_node" "$call_node" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker image rm "$zig_image" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

show_logs() {
  for container in "$@"; do
    if docker inspect "$container" >/dev/null 2>&1; then
      echo "--- $container (last 250 lines) ---" >&2
      docker logs --tail 250 "$container" >&2 || true
    fi
  done
}

fail() {
  echo "EVM_ACCEPTANCE FAIL: $*" >&2
  show_logs "$one_node" "$deploy_node" "$call_node"
  exit 1
}

wait_for_log() {
  container=$1
  needle=$2
  limit=$3
  attempt=0

  while [ "$attempt" -lt "$limit" ]; do
    logs=$(docker logs "$container" 2>&1 || true)
    if printf '%s\n' "$logs" | grep -Fq "$needle"; then
      return 0
    fi

    running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)
    if [ "$running" != true ]; then
      fail "$container stopped before logging: $needle"
    fi

    attempt=$((attempt + 1))
    sleep 1
  done

  fail "$container did not log within ${limit}s: $needle"
}

assert_log() {
  container=$1
  needle=$2
  logs=$(docker logs "$container" 2>&1 || true)
  if ! printf '%s\n' "$logs" | grep -Fq "$needle"; then
    fail "$container is missing log: $needle"
  fi
}

assert_exact_log() {
  container=$1
  line=$2
  logs=$(docker logs "$container" 2>&1 || true)
  if ! printf '%s\n' "$logs" | grep -Fxq "$line"; then
    fail "$container is missing exact log line: $line"
  fi
}

assert_running() {
  container=$1
  running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)
  if [ "$running" != true ]; then
    fail "$container is not running"
  fi
}

echo "[1/5] Building the pinned Zig ${ZIG_VERSION} toolchain image"
docker build \
  --build-arg "ZIG_VERSION=$ZIG_VERSION" \
  -t "$zig_image" \
  .

actual_zig_version=$(docker run --rm "$zig_image" zig version)
if [ "$actual_zig_version" != "$ZIG_VERSION" ]; then
  fail "expected Zig $ZIG_VERSION, got $actual_zig_version"
fi
echo "ZIG_VERSION PASS: $actual_zig_version"

echo "[2/5] Compiling SimpleAdder.sol with pinned solc ${SOLC_VERSION}"
solc_version_output=$(docker run --rm --platform linux/amd64 "$SOLC_IMAGE" --version 2>&1)
if ! printf '%s\n' "$solc_version_output" | grep -Fq "Version: $SOLC_FULL_VERSION"; then
  printf '%s\n' "$solc_version_output" >&2
  fail "unexpected solc version"
fi

compiled=$(docker run --rm \
  --platform linux/amd64 \
  -v "$PWD:/src:ro" \
  "$SOLC_IMAGE" \
  --bin --hashes --evm-version berlin /src/contract/SimpleAdder.sol)

creation_bytecode=$(printf '%s\n' "$compiled" | awk '/^Binary:/{getline; print; exit}')
selector=$(printf '%s\n' "$compiled" | awk '/add\(uint256,uint256\)/{sub(/:.*/, "", $1); print $1; exit}')

if [ -z "$creation_bytecode" ]; then
  fail "solc did not emit Adder creation bytecode"
fi
case "$creation_bytecode" in
  *[!0-9a-fA-F]*) fail "solc emitted non-hex creation bytecode" ;;
esac
if [ $(( ${#creation_bytecode} % 2 )) -ne 0 ]; then
  fail "solc emitted odd-length creation bytecode"
fi
if [ "$selector" != 771602f7 ]; then
  fail "expected add(uint256,uint256) selector 771602f7, got $selector"
fi

arg_a=$(printf '%064x' 2)
arg_b=$(printf '%064x' 3)
calldata="0x${selector}${arg_a}${arg_b}"
if [ "${#calldata}" -ne 138 ]; then
  fail "expected 138-character ABI calldata, got ${#calldata}"
fi
echo "SOLC_COMPILE PASS: version=$SOLC_FULL_VERSION selector=$selector creation_bytes=$(( ${#creation_bytecode} / 2 ))"

echo "[3/5] Running Zig formatting, all unit tests, and the ABI EVM test"
docker run --rm \
  --user "$DOCKER_USER" \
  -v "$PWD:/work:ro" \
  -v "$scratch:/scratch" \
  -w /work \
  "$zig_image" \
  sh -c 'zig fmt --check build.zig src && zig build test --cache-dir /scratch/cache --global-cache-dir /scratch/global --prefix /scratch/out --summary all'

docker run --rm \
  --user "$DOCKER_USER" \
  -v "$PWD:/work:ro" \
  -v "$scratch:/scratch" \
  -w /work \
  "$zig_image" \
  zig test src/evm.zig \
  --test-filter 'ABI calldataでadd関数を実行' \
  --cache-dir /scratch/abi-cache \
  --global-cache-dir /scratch/global

# Build once, then run this exact executable in every process below. This avoids
# separate build races and proves that the same artifact works in both scenarios.
docker run --rm \
  --user "$DOCKER_USER" \
  -v "$PWD:/work:ro" \
  -v "$scratch:/scratch" \
  -w /work \
  "$zig_image" \
  zig build \
  --cache-dir /scratch/cache \
  --global-cache-dir /scratch/global \
  --prefix /scratch/out
executable=$(docker run --rm \
  --user "$DOCKER_USER" \
  -v "$scratch:/scratch:ro" \
  "$zig_image" \
  sh -ec '
    if test -x /scratch/out/bin/evmchapter; then
      echo /scratch/out/bin/evmchapter
    elif test -x /scratch/out/bin/blockchain; then
      echo /scratch/out/bin/blockchain
    else
      exit 1
    fi
  ') || fail "Zig build did not produce evmchapter or blockchain"
echo "ZIG_EVM_TESTS PASS"

echo "[4/5] Executing one-node deploy and add(2,3) call"
docker run -d \
  --name "$one_node" \
  --user "$DOCKER_USER" \
  -v "$scratch:/scratch:ro" \
  "$zig_image" \
  "$executable" \
  --listen 19000 \
  --deploy "$creation_bytecode" "$CONTRACT_ADDRESS" \
  --call "$CONTRACT_ADDRESS" "$calldata" \
  --gas 3000000 \
  --sender "$SENDER_ADDRESS" \
  >/dev/null

wait_for_log "$one_node" 'コントラクトデプロイブロックを作成しました' 120
wait_for_log "$one_node" 'EVM実行結果(u256): 5' 120
assert_exact_log "$one_node" 'info: EVM実行結果(u256): 5'
assert_log "$one_node" 'コントラクトが正常にデプロイされました'
assert_running "$one_node"
echo "ONE_NODE_EVM PASS: add(2,3)=5"
docker rm -f "$one_node" >/dev/null

echo "[5/5] Executing two-node deployment sync and call"
docker network create "$network" >/dev/null

docker run -d \
  --name "$deploy_node" \
  --network "$network" \
  --user "$DOCKER_USER" \
  -v "$scratch:/scratch:ro" \
  "$zig_image" \
  "$executable" \
  --listen 19000 \
  --deploy "$creation_bytecode" "$CONTRACT_ADDRESS" \
  --gas 3000000 \
  --sender "$SENDER_ADDRESS" \
  >/dev/null

wait_for_log "$deploy_node" 'コントラクトデプロイブロックを作成しました' 120

# Pause the already-deployed node until the caller has recorded its pending call.
# A host kernel may still complete the TCP handshake while the container's
# userspace is paused, so the portable invariant is the missing local contract,
# not whether the transaction was also queued by the P2P layer.
docker pause "$deploy_node" >/dev/null

docker run -d \
  --name "$call_node" \
  --network "$network" \
  --user "$DOCKER_USER" \
  -v "$scratch:/scratch:ro" \
  "$zig_image" \
  "$executable" \
  --listen 19001 \
  --connect "$deploy_node:19000" \
  --call "$CONTRACT_ADDRESS" "$calldata" \
  --gas 100000 \
  --sender "$SENDER_ADDRESS" \
  >/dev/null

wait_for_log "$call_node" 'コントラクトがローカルに見つかりません。チェーン同期後に実行します' 30
docker unpause "$deploy_node" >/dev/null

wait_for_log "$call_node" 'Chain synchronization completed with peer' 120
wait_for_log "$call_node" 'Contract call executed successfully after chain synchronization' 120
wait_for_log "$call_node" 'EVM実行結果(u256): 5' 120
wait_for_log "$deploy_node" 'EVM実行結果(u256): 5' 120

assert_log "$call_node" 'Received block contains 1 contracts'
assert_log "$call_node" "Updated contract $CONTRACT_ADDRESS"
assert_exact_log "$call_node" 'info: EVM実行結果(u256): 5'
assert_exact_log "$deploy_node" 'info: EVM実行結果(u256): 5'
assert_running "$deploy_node"
assert_running "$call_node"

call_logs=$(docker logs "$call_node" 2>&1 || true)
if printf '%s\n' "$call_logs" | grep -Fq 'Message too long'; then
  fail "deployment block exceeded the P2P receive frame"
fi

echo "TWO_NODE_EVM PASS: deployment synchronized and add(2,3)=5 on both nodes"
echo "EVM_ACCEPTANCE PASS"
echo "zig=$ZIG_VERSION"
echo "solc=$SOLC_FULL_VERSION"
echo "selector=$selector"
echo "one_node_result=5"
echo "two_node_sync=complete"
echo "two_node_result=5"
