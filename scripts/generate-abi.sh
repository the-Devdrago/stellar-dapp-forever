#!/usr/bin/env bash
# generate-abi.sh — Issue #135
#
# Extracts the contract's XDR spec from the compiled wasm and writes it to
# contract-interface.json alongside a human-readable summary.
#
# Usage:
#   ./scripts/generate-abi.sh          # builds and generates
#   ./scripts/generate-abi.sh --check  # exits non-zero if output differs from
#                                      # what a fresh generation would produce
#                                      # (used in CI to detect drift)
#
# Prerequisites:
#   - Rust + wasm32v1-none target (see CONTRIBUTING.md)
#   - stellar CLI: https://developers.stellar.org/docs/tools/developer-tools/cli/stellar-cli

set -euo pipefail

WASM_PATH="contracts/dao/target/wasm32v1-none/release/stellar_dapp_forever.wasm"
OUT_DIR="contract"
OUT_JSON="${OUT_DIR}/contract-interface.json"
OUT_SUMMARY="${OUT_DIR}/interface-summary.txt"
CHECK_MODE=false

for arg in "$@"; do
  case $arg in
    --check) CHECK_MODE=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

echo "Building contract wasm..."
cargo build --target wasm32v1-none --release -p stellar-dapp-forever 2>&1 | tail -5

if [ ! -f "$WASM_PATH" ]; then
  echo "Error: wasm not found at $WASM_PATH after build" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
FRESH_JSON="$(mktemp)"

echo "Extracting contract spec from wasm..."
stellar contract inspect --wasm "$WASM_PATH" --output json > "$FRESH_JSON"

if $CHECK_MODE; then
  if [ ! -f "$OUT_JSON" ]; then
    echo "CI drift check FAILED: $OUT_JSON does not exist." >&2
    echo "Run ./scripts/generate-abi.sh and commit the result." >&2
    exit 1
  fi
  if ! diff -q "$OUT_JSON" "$FRESH_JSON" > /dev/null 2>&1; then
    echo "CI drift check FAILED: $OUT_JSON is stale." >&2
    echo "Diff:" >&2
    diff "$OUT_JSON" "$FRESH_JSON" >&2
    echo "" >&2
    echo "Run ./scripts/generate-abi.sh and commit the result." >&2
    exit 1
  fi
  echo "CI drift check PASSED: $OUT_JSON matches a fresh generation."
else
  cp "$FRESH_JSON" "$OUT_JSON"
  # Also write a human-readable summary for the README.
  stellar contract inspect --wasm "$WASM_PATH" --output xdr-base64-array > "$OUT_SUMMARY" 2>/dev/null || true
  echo "Generated: $OUT_JSON"
  echo "Generated: $OUT_SUMMARY"
  echo ""
  echo "Remember to commit both files and update README.md to link to"
  echo "contract/contract-interface.json instead of the hand-written ABI table."
fi

rm -f "$FRESH_JSON"
