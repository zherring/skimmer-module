#!/usr/bin/env bash
# Keeper for a YieldSkimmer: poke skim() when there is something to skim, then pull() every recipient that is due.
#
# Env:
#   SKIMMER             YieldSkimmer address (required)
#   RPC_URL             Base RPC endpoint (required)
#   KEEPER_PRIVATE_KEY  gas-only EOA; it only ever calls permissionless functions (required unless DRY_RUN=1)
#   DRY_RUN=1           read state and print the `cast send` commands instead of sending them
#
# Exit status: non-zero only when skim() itself fails (or the state needed to decide about it cannot be read, or the
# environment is incomplete). A failed pull() is logged and the run goes on; it never fails the run.
# Needs only `cast` and `jq`. All output goes to stdout so a caller can tee it to a log.
set -euo pipefail

DRY_RUN="${DRY_RUN:-}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() {
  log "ERROR: $*"
  exit 1
}

: "${SKIMMER:?set SKIMMER to the YieldSkimmer address}"
: "${RPC_URL:?set RPC_URL to a Base RPC endpoint}"
if [[ "$DRY_RUN" != "1" ]]; then
  : "${KEEPER_PRIVATE_KEY:?set KEEPER_PRIVATE_KEY to the gas-only keeper key (or DRY_RUN=1)}"
fi

ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT

# Tool output can echo the RPC URL (it usually carries an API key) and the run log is uploaded as an artifact.
scrub() {
  local s="$*"
  s="${s//"$RPC_URL"/<RPC_URL>}"
  if [[ -n "${KEEPER_PRIVATE_KEY:-}" ]]; then s="${s//"$KEEPER_PRIVATE_KEY"/<KEEPER_PRIVATE_KEY>}"; fi
  printf '%s' "$s" | tr '\n' ' '
}

# read_call <sig> [args...]: eth_call on the skimmer; prints the returned values tab-separated.
read_call() {
  local out
  if ! out="$(cast call "$SKIMMER" "$@" --json --rpc-url "$RPC_URL" 2>"$ERR_FILE")"; then
    log "read failed: $1: $(scrub "$(cat "$ERR_FILE")")"
    return 1
  fi
  jq -r 'map(tostring) | @tsv' <<<"$out"
}

# send <label> <sig> [args...]: a transaction from the keeper to the skimmer. Returns 0 only on a successful receipt.
send() {
  local label="$1" out status tx gas args
  shift
  if [[ "$DRY_RUN" == "1" ]]; then
    args="$(printf '"%s" ' "$@")"
    log "DRY_RUN: cast send $SKIMMER ${args}--rpc-url \"\$RPC_URL\" --private-key \"\$KEEPER_PRIVATE_KEY\""
    return 0
  fi
  if ! out="$(cast send "$SKIMMER" "$@" --json --rpc-url "$RPC_URL" --private-key "$KEEPER_PRIVATE_KEY" 2>"$ERR_FILE")"; then
    log "$label: send failed: $(scrub "$(cat "$ERR_FILE")" | cut -c1-240)"
    return 1
  fi
  status="$(jq -r '.status // empty' <<<"$out")"
  tx="$(jq -r '.transactionHash // empty' <<<"$out")"
  gas="$(jq -r '.gasUsed // empty' <<<"$out")"
  if [[ "$status" == "0x1" || "$status" == "1" ]]; then
    log "$label: ok tx=$tx gasUsed=$gas"
    return 0
  fi
  log "$label: reverted tx=$tx status=${status:-unknown}"
  return 1
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

chain_id="$(cast chain-id --rpc-url "$RPC_URL" 2>"$ERR_FILE")" || die "cannot reach the RPC: $(scrub "$(cat "$ERR_FILE")")"
log "keeper start: skimmer=$SKIMMER chain=$chain_id dry_run=${DRY_RUN:-0}"
if [[ "$DRY_RUN" != "1" ]]; then
  keeper_addr="$(cast wallet address --private-key "$KEEPER_PRIVATE_KEY")" || die "KEEPER_PRIVATE_KEY is not a valid key"
  keeper_wei="$(cast balance "$keeper_addr" --rpc-url "$RPC_URL" 2>/dev/null || echo unknown)"
  log "keeper address=$keeper_addr balance_wei=$keeper_wei"
fi

# --- paused ---------------------------------------------------------------------------------------------------------
paused="$(read_call "paused()(bool)")" || die "cannot read paused()"
if [[ "$paused" == "true" ]]; then
  log "skimmer is paused: nothing to do"
  exit 0
fi

# --- skim -----------------------------------------------------------------------------------------------------------
last_skim="$(read_call "lastSkim()(uint256)")" || die "cannot read lastSkim()"
preview="$(read_call "previewSkim()(uint256,uint256)")" || die "cannot read previewSkim()"
IFS=$'\t' read -r yield_amt take <<<"$preview"
if ! { is_uint "$last_skim" && is_uint "$yield_amt" && is_uint "$take"; }; then
  die "unexpected values: lastSkim=$last_skim previewSkim=($yield_amt, $take)"
fi
log "previewSkim: yieldAmt=$yield_amt take=$take lastSkim=$last_skim"

skim_status=0
if [[ "$last_skim" == "0" ]]; then
  log "lastSkim is 0: the first skim records the starting watermark"
  send "skim" "skim()" || skim_status=1
elif [[ "$take" != "0" ]]; then
  send "skim" "skim()" || skim_status=1
else
  log "skip skim: previewSkim take is 0 (a no-op skim only costs gas)"
fi

# --- pulls ----------------------------------------------------------------------------------------------------------
# Read after the skim so this run pulls what it just credited. One recipient failing never stops the others.
pulls_ok=0
pulls_failed=0
if count="$(read_call "recipientCount()(uint256)")" && now="$(cast block latest --field timestamp --rpc-url "$RPC_URL" 2>"$ERR_FILE")" && is_uint "$count" && is_uint "$now"; then
  log "recipients: count=$count chain_time=$now"
  for ((i = 0; i < count; i++)); do
    r="$(read_call "recipientAt(uint256)(address)" "$i")" || {
      log "recipient[$i]: cannot read recipientAt: skipping"
      continue
    }
    rec="$(read_call "recipients(address)(uint16,uint32,uint64,uint256)" "$r")" || {
      log "recipient $r: cannot read recipients(): skipping"
      continue
    }
    IFS=$'\t' read -r share_bps min_interval last_pull accrued <<<"$rec"
    if ! { is_uint "$last_pull" && is_uint "$min_interval"; }; then
      log "recipient $r: unexpected values lastPull=$last_pull minInterval=$min_interval: skipping"
      continue
    fi
    available_at=$((last_pull + min_interval))
    if [[ "$accrued" == "0" ]]; then
      log "recipient $r: skip pull, nothing accrued (shareBps=$share_bps)"
    elif ((now < available_at)); then
      log "recipient $r: skip pull, accrued=$accrued but not due until $available_at (minInterval=$min_interval lastPull=$last_pull)"
    else
      log "recipient $r: pulling accrued=$accrued"
      if send "pull($r)" "pull(address)" "$r"; then
        pulls_ok=$((pulls_ok + 1))
      else
        pulls_failed=$((pulls_failed + 1))
        log "recipient $r: pull failed, continuing"
      fi
    fi
  done
else
  log "cannot read the recipient list or the chain time: skipping pulls"
fi

log "keeper done: skim_status=$skim_status pulls_ok=$pulls_ok pulls_failed=$pulls_failed"
exit "$skim_status"
