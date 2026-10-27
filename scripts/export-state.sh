#!/usr/bin/env bash
#
# Dumps the live state of a deployed stellar-dapp-forever contract (#336).
# Every value comes from a read-only view, simulated with `--send=no`, so nothing
# is signed or submitted. This is step 3 of the migration procedure in
# docs/MIGRATION.md: run it as soon as the contract is paused, then again if
# you need a later snapshot.
#
# Usage:
#   ./scripts/export-state.sh [options] <contract-id>
#
# Options:
#   --out <file>          Write the JSON to <file> instead of stdout.
#   --network <name>      Network to read from (default: testnet).
#   -h, --help            Show this help.
#
# Environment overrides:
#   IDENTITY    stellar keys identity used to simulate the reads (default: stellar-dapp-forever-deployer).
#               It needs to exist but holds no funds.
#   PAGE_SIZE   member records fetched per list_members call (default: 100).
#
# What cannot be read live:
#   - Members come from list_members, which skips records whose storage entry
#     has expired. The script warns when it exports fewer members than
#     get_total_members reports. Those members need recovering another way (see
#     the TTL section of docs/MIGRATION.md).
#   - Names are looked up per member with name_of. A name held by an address
#     that is not in the member list cannot be enumerated and is not exported.
#   - Loans and proposals are read by id, from 0 up to their counters. Ids with
#     no record come back as null and are left out.
#
# Requires the stellar CLI and jq.
set -euo pipefail

NETWORK="${NETWORK:-testnet}"
IDENTITY="${IDENTITY:-stellar-dapp-forever-deployer}"
PAGE_SIZE="${PAGE_SIZE:-100}"
CONTRACT_ID=""
OUT=""

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || die "--out needs a value"
      OUT="$2"
      shift
      ;;
    --network)
      [[ $# -ge 2 ]] || die "--network needs a value"
      NETWORK="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      [[ -z "${CONTRACT_ID}" ]] || die "unexpected argument: $1 (see --help)"
      CONTRACT_ID="$1"
      ;;
  esac
  shift
done

[[ -n "${CONTRACT_ID}" ]] || die "missing <contract-id> (see --help)"
command -v stellar >/dev/null 2>&1 ||
  die "the 'stellar' CLI is not installed. See https://developers.stellar.org/docs/tools/developer-tools/cli/stellar-cli"
command -v jq >/dev/null 2>&1 || die "jq is not installed (https://jqlang.github.io/jq/)"

# view <fn> [args...]: simulate a read-only call and print its JSON result.
view() {
  stellar contract invoke --id "${CONTRACT_ID}" --source "${IDENTITY}" \
    --network "${NETWORK}" --send=no -- "$@" </dev/null
}

# collect <out-file> <count-fn> <get-fn> <id-arg>: append every non-null record
# for ids 0..count-1 to <out-file>, one JSON object per line.
collect() {
  local out="$1" count_fn="$2" get_fn="$3" id_arg="$4"
  local count id record
  count="$(view "${count_fn}")"
  : >"${out}"
  for ((id = 0; id < count; id++)); do
    record="$(view "${get_fn}" "--${id_arg}" "${id}")"
    if [[ "${record}" != "null" ]]; then
      jq -c . <<<"${record}" >>"${out}"
    fi
  done
}

# collect_documents <kind> <count-fn>: append every attached content hash for
# proposals of <kind> to documents.ndjson.
collect_documents() {
  local kind="$1" count_fn="$2"
  local count id hash
  count="$(view "${count_fn}")"
  for ((id = 0; id < count; id++)); do
    hash="$(view get_document --kind "${kind}" --proposal_id "${id}")"
    if [[ "${hash}" != "null" ]]; then
      jq -nc --arg kind "${kind}" --argjson proposal_id "${id}" --argjson content_hash "${hash}" \
        '{kind: $kind, proposal_id: $proposal_id, content_hash: $content_hash}' \
        >>"${WORK}/documents.ndjson"
    fi
  done
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "==> Reading ${CONTRACT_ID} on ${NETWORK}" >&2

VERSION="$(view get_version)"
ADMINS="$(view get_admins)"
THRESHOLD="$(view get_consensus_threshold)"
POLICY="$(view get_loan_policy)"
TOKEN="$(view get_token)"
PAUSED="$(view is_paused)"
TOTAL_MEMBERS="$(view get_total_members)"
ACTIVE_MEMBERS="$(view get_active_members)"
WHITELISTED="$(view get_whitelisted_tokens)"

echo "==> Members" >&2
: >"${WORK}/members.ndjson"
offset=0
while ((offset < TOTAL_MEMBERS)); do
  view list_members --start "${offset}" --limit "${PAGE_SIZE}" | jq -c '.[]' >>"${WORK}/members.ndjson"
  offset=$((offset + PAGE_SIZE))
done

exported_members="$(wc -l <"${WORK}/members.ndjson" | tr -d ' ')"
if ((exported_members != TOTAL_MEMBERS)); then
  echo "warning: exported ${exported_members} of ${TOTAL_MEMBERS} members. The rest have expired storage; see docs/MIGRATION.md (TTL risk)." >&2
fi

: >"${WORK}/member_rows.ndjson"
while IFS= read -r member; do
  address="$(jq -r '.address' <<<"${member}")"
  stake="$(view get_stake --member "${address}")"
  pending="$(view get_pending_yield --member "${address}")"
  name="$(view name_of --owner "${address}")"
  jq -c --argjson stake "${stake}" --argjson pending_yield "${pending}" --argjson name "${name}" \
    '. + {stake: $stake, pending_yield: $pending_yield, name: $name}' <<<"${member}" \
    >>"${WORK}/member_rows.ndjson"
done <"${WORK}/members.ndjson"

echo "==> Treasury balances" >&2
: >"${WORK}/assets.ndjson"
while IFS= read -r asset; do
  balance="$(view get_treasury_balance_in_asset --asset "${asset}")"
  jq -nc --arg asset "${asset}" --argjson balance "${balance}" '{asset: $asset, balance: $balance}' \
    >>"${WORK}/assets.ndjson"
done < <(jq -r '.[]' <<<"${WHITELISTED}")

echo "==> Loans and proposals" >&2
collect "${WORK}/loan_proposals.ndjson" get_loan_proposal_count get_loan_proposal proposal_id
collect "${WORK}/loans.ndjson" get_loan_proposal_count get_loan loan_id
collect "${WORK}/treasury_proposals.ndjson" get_treasury_proposal_count get_treasury_proposal proposal_id

echo "==> Documents" >&2
: >"${WORK}/documents.ndjson"
collect_documents Loan get_loan_proposal_count
collect_documents Treasury get_treasury_proposal_count

export_json() {
  jq -n \
    --arg contract_id "${CONTRACT_ID}" \
    --arg network "${NETWORK}" \
    --arg exported_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson version "${VERSION}" \
    --argjson admins "${ADMINS}" \
    --argjson consensus_threshold "${THRESHOLD}" \
    --argjson loan_policy "${POLICY}" \
    --argjson token "${TOKEN}" \
    --argjson paused "${PAUSED}" \
    --argjson total_members "${TOTAL_MEMBERS}" \
    --argjson active_members "${ACTIVE_MEMBERS}" \
    --slurpfile treasury_balances "${WORK}/assets.ndjson" \
    --slurpfile members "${WORK}/member_rows.ndjson" \
    --slurpfile loan_proposals "${WORK}/loan_proposals.ndjson" \
    --slurpfile loans "${WORK}/loans.ndjson" \
    --slurpfile treasury_proposals "${WORK}/treasury_proposals.ndjson" \
    --slurpfile documents "${WORK}/documents.ndjson" \
    '{
      contract_id: $contract_id,
      network: $network,
      exported_at: $exported_at,
      version: $version,
      admins: $admins,
      consensus_threshold: $consensus_threshold,
      loan_policy: $loan_policy,
      token: $token,
      paused: $paused,
      total_members: $total_members,
      active_members: $active_members,
      treasury_balances: $treasury_balances,
      members: $members,
      loan_proposals: $loan_proposals,
      loans: $loans,
      treasury_proposals: $treasury_proposals,
      documents: $documents
    }'
}

if [[ -n "${OUT}" ]]; then
  export_json >"${OUT}"
  echo "==> Wrote ${OUT}" >&2
else
  export_json
fi
