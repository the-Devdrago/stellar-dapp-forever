#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${REPRO_IMAGE:-stellar-dapp-forever-reproducible:rust-1.98.1-stellar-28.0.0}"
OUT_A_REL="target/reproducible-a"
OUT_B_REL="target/reproducible-b"
OUT_A="$ROOT_DIR/$OUT_A_REL"
OUT_B="$ROOT_DIR/$OUT_B_REL"

command -v docker >/dev/null 2>&1 || {
  echo "error: docker is required for reproducible builds" >&2
  exit 1
}

rm -rf "$OUT_A" "$OUT_B"
mkdir -p "$OUT_A" "$OUT_B"

echo "Building pinned reproducible image $IMAGE"
docker build \
  --file "$ROOT_DIR/Dockerfile.reproducible" \
  --tag "$IMAGE" \
  "$ROOT_DIR"

build_once() {
  local out_rel="$1"
  docker run --rm \
    --volume "$ROOT_DIR:/workspace" \
    --workdir /workspace \
    --env CARGO_TARGET_DIR=/tmp/cargo-target \
    "$IMAGE" \
    contract build \
    --locked \
    --package stellar-dapp-forever \
    --optimize=false \
    --out-dir "/workspace/$out_rel"
}

echo "Running isolated build A"
build_once "$OUT_A_REL"
echo "Running isolated build B"
build_once "$OUT_B_REL"

WASM_A="$(find "$OUT_A" -maxdepth 1 -type f -name '*.wasm' | sort | head -n 1)"
WASM_B="$(find "$OUT_B" -maxdepth 1 -type f -name '*.wasm' | sort | head -n 1)"

if [[ -z "$WASM_A" || -z "$WASM_B" ]]; then
  echo "error: one or both container builds produced no wasm" >&2
  exit 1
fi

HASH_A="$(sha256sum "$WASM_A" | awk '{print $1}')"
HASH_B="$(sha256sum "$WASM_B" | awk '{print $1}')"

echo "build A sha256: $HASH_A"
echo "build B sha256: $HASH_B"

if [[ "$HASH_A" != "$HASH_B" ]]; then
  echo "error: reproducible-build hash mismatch" >&2
  exit 1
fi

echo "reproducible build verified: $HASH_A"