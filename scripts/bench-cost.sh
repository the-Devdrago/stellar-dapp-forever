#!/usr/bin/env bash
set -euo pipefail

echo "Measuring entrypoint costs at DAO sizes 10, 100, 1000..."
echo "Entrypoints: request_loan_in_asset, repay_loan_in_asset, propose_withdrawal_in_asset, exit_dao"
cargo test --locked -p stellar-dapp-forever --features bench-budget test_budget_scaling -- --nocapture > budget_out.txt || true

# The benchmark lives in contracts/dao/src/bench.rs and prints one
# `BENCH <entrypoint> <size> <cpu>` line per measurement.
echo "Checking for O(n) regressions..."
if ! grep -q "^BENCH " budget_out.txt; then
    echo "Benchmark produced no results (did it fail to build or panic?)"
    cat budget_out.txt
    exit 1
fi
grep "^BENCH " budget_out.txt
if grep -q "REGRESSION" budget_out.txt; then
    echo "Cost regression detected!"
    grep "REGRESSION" budget_out.txt
    exit 1
fi
echo "Budget OK."