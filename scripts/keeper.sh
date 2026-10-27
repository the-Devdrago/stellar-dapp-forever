#!/usr/bin/env bash
#
# Keeper for a deployed stellar-dapp-forever contract (#337, #338). Every call it makes is
# permissionless on-chain, so anyone can run this from cron:
#
#   1. Defaults: mark_loan_defaulted for each active loan whose
#      due_time + default_grace_period has passed.
#   2. Loan expiry: expire_loan_proposal for each pending loan proposal whose
#      editing and voting windows have closed.
#   3. Treasury expiry: expire_treasury_proposal for each pending treasury
#      proposal whose voting period has closed.
#
# Each pass reads state with read-only simulations and submits a transaction
# only for records that are due. The contract stays the authority: a call it
# rejects is reported as FAILED and retried on the next run. The script exits
# non-zero when any call failed, so cron mail or monitoring can pick it up.
# While the contract is paused the script does nothing and exits 0.
#
# Usage:
#   ./scripts/keeper.sh [options] <contract-id>
#
# Options:
#   --dry-run             Read state and print what would be submitted. Submits nothing.
#   --network <name>      Network to run against (default: testnet).
#   -h, --help            Show this help.
#
# Environment overrides:
#   IDENTITY    stellar keys identity that pays the fees (default: stellar-dapp-forever-keeper).
#               It must already exist and be funded, e.g.:
#               stellar keys generate stellar-dapp-forever-keeper --network testnet --fund
#
# Example crontab entry (every 15 minutes):
#   */15 * * * * /path/to/stellar-dapp-forever/scripts/keeper.sh --network testnet <contract-id> >> ~/stellar-dapp-forever-keeper.log 2>&1
#
# Due times use this machine's clock. A record can look due a few seconds
# before the ledger agrees; the contract then rejects it and the next run
# submits it.
#
# Requires the stellar CLI and jq.
set -euo pipefail

NETWORK="${NETWORK:-testnet}"
IDENTITY="${IDENTITY:-stellar-dapp-forever-keeper}"
CONTRACT_ID=""
DRY_RUN=0
DUE=0
SUBMITTED=0
FAILED=0

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
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
stellar keys address "${IDENTITY}" >/dev/null 2>&1 ||
  die "identity '${IDENTITY}' does not exist. Create it first: stellar keys generate ${IDENTITY} --network ${NETWORK} --fund"

# view <fn> [args...]: simulate a read-only call and print its JSON result.
view() {
  stellar contract invoke --id "${CONTRACT_ID}" --source "${IDENTITY}" \
    --network "${NETWORK}" --send=no -- "$@" </dev/null
}

# submit <fn> [args...]: send a state-changing call. Exits non-zero if the
# contract rejects it or the network fails.
submit() {
  stellar contract invoke --id "${CONTRACT_ID}" --source "${IDENTITY}" \
    --network "${NETWORK}" -- "$@" </dev/null >/dev/null
}

# sweep <label> <count-fn> <get-fn> <submit-fn> <id-arg> <due-filter>
# Calls <submit-fn> for each record that <due-filter> accepts. Ids run from 0 to
# <count-fn>; <get-fn> and <submit-fn> both take the id as <id-arg>.
sweep() {
  local label="$1" count_fn="$2" get_fn="$3" submit_fn="$4" id_arg="$5" due_filter="$6"
  local count id record
  echo "==> ${label}"
  count="$(view "${count_fn}")"
  for ((id = 0; id < count; id++)); do
    record="$(view "${get_fn}" "--${id_arg}" "${id}")"
    if [[ "${record}" == "null" ]]; then
      continue
    fi
    if ! jq -e --arg now "${NOW}" --arg grace "${GRACE}" "${due_filter}" <<<"${record}" >/dev/null; then
      continue
    fi
    DUE=$((DUE + 1))
    if ((DRY_RUN)); then
      echo "    would call ${submit_fn} --${id_arg} ${id}"
    elif submit "${submit_fn}" "--${id_arg}" "${id}"; then
      SUBMITTED=$((SUBMITTED + 1))
      echo "    called ${submit_fn} --${id_arg} ${id}"
    else
      FAILED=$((FAILED + 1))
      echo "    FAILED ${submit_fn} --${id_arg} ${id}; retried on the next run" >&2
    fi
  done
}

if [[ "$(view is_paused)" == "true" ]]; then
  echo "==> Contract is paused; keeper passes are blocked until it is unpaused. Nothing submitted."
  exit 0
fi

NOW="$(date +%s)"
GRACE="$(view get_loan_policy | jq -r '.default_grace_period')"

# Loan ids equal their proposal ids, so the loan pass counts loan proposals.
sweep "Pass 1: loan defaults" get_loan_proposal_count get_loan mark_loan_defaulted loan_id \
  '.status == "Active" and (($now | tonumber) >= (.due_time | tonumber) + ($grace | tonumber))'

sweep "Pass 2: loan proposal expiry" get_loan_proposal_count get_loan_proposal \
  expire_loan_proposal proposal_id \
  '.status == "Pending" and (($now | tonumber) > (.editing_period_end | tonumber) + (.voting_period | tonumber))'

sweep "Pass 3: treasury proposal expiry" get_treasury_proposal_count get_treasury_proposal \
  expire_treasury_proposal proposal_id \
  '.status == "Pending" and (($now | tonumber) > (.created_at | tonumber) + (.voting_period | tonumber))'

echo ""
if ((DRY_RUN)); then
  echo "==> Dry run: ${DUE} record(s) due, nothing submitted."
else
  echo "==> Done: ${DUE} due, ${SUBMITTED} submitted, ${FAILED} failed."
fi
((FAILED == 0)) || exit 1
