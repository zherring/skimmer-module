#!/usr/bin/env bash
# Integration test of ops/keeper.sh and the deploy script against a local anvil fork of Base.
#
#   BASE_RPC_URL=https://mainnet.base.org ops/test-keeper.sh
#
# What is real: the Splits Earn wrapper, a SmartVault created through the real factory, the real USDC, the
# deployed YieldSkimmer (via script/DeployYieldSkimmer.s.sol, CREATE2) and the keeper script.
# What is faked, all through anvil RPCs (no keys other than anvil's well-known dev keys are involved):
#   - the account's USDC is written straight into USDC's balance storage (the `deal` equivalent);
#   - the account's txs (deposit, enableModule, addRecipient, pause) are sent by impersonating the account;
#   - one recipient is blacklisted in USDC by setting the blacklist bit in its balance slot, so its pull() reverts.
# Needs: anvil, forge, cast, jq. Anvil is killed on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM_RPC="${BASE_RPC_URL:-https://mainnet.base.org}"
FALLBACK_RPC="https://base-rpc.publicnode.com"
PORT="${ANVIL_PORT:-18545}"
LOCAL="http://127.0.0.1:$PORT"

USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
VAULT=0x189A1a23F46321a196646314E6a078a404513C8F
FACTORY=0x8E6Af8Ed94E87B4402D0272C5D6b0D47F0483e7C
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000

# anvil's default dev accounts 0..2: deployer, SmartVault owner/signer, keeper.
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OWNER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
KEEPER_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
KEEPER_ADDR=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

# Fresh addresses (zero USDC): BAD gets blacklisted in USDC so its pull() reverts.
BAD_RECIPIENT="$(cast wallet new --json | jq -r '.[0].address')"
GOOD_RECIPIENT="$(cast wallet new --json | jq -r '.[0].address')"

DEPOSIT=100000000000 # 100,000 USDC

TMP="$(mktemp -d)"
ANVIL_PID=""
cleanup() {
  local rc=$?
  if ((rc != 0)) && [[ -s "$TMP/anvil.log" ]]; then
    echo "--- anvil log (tail) ---" >&2
    tail -n 15 "$TMP/anvil.log" >&2
  fi
  if [[ -n "$ANVIL_PID" ]]; then kill "$ANVIL_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
assert_eq() { [[ "$2" == "$3" ]] || fail "$1: got '$2', expected '$3'"; }
assert_gt() { (($2 > $3)) || fail "$1: got $2, expected > $3"; }
assert_near() { local d=$(($2 > $3 ? $2 - $3 : $3 - $2)); ((d <= $4)) || fail "$1: got $2, expected within $4 of $3"; }
assert_contains() { grep -q -- "$3" <<<"$2" || fail "$1: output does not contain '$3'"; }
echo_ok() { printf 'ok   %s\n' "$*"; }

# First word of a cast call result, with cast's "123 [1.23e2]" annotation dropped.
call() { cast call "$@" --rpc-url "$LOCAL" | awk '{print $1}'; }
rpc() { cast rpc "$@" --rpc-url "$LOCAL" >/dev/null; }

# --- anvil ----------------------------------------------------------------------------------------------------------
if cast chain-id --rpc-url "$LOCAL" >/dev/null 2>&1; then fail "something already listens on $LOCAL (set ANVIL_PORT)"; fi
fork_url="$UPSTREAM_RPC"
if ! cast chain-id --rpc-url "$fork_url" >/dev/null 2>&1; then
  echo "upstream RPC unreachable, falling back to $FALLBACK_RPC"
  fork_url="$FALLBACK_RPC"
fi

step "anvil fork of Base on :$PORT"
anvil --fork-url "$fork_url" --chain-id 8453 --port "$PORT" --silent >"$TMP/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 60); do
  if cast chain-id --rpc-url "$LOCAL" >/dev/null 2>&1; then break; fi
  kill -0 "$ANVIL_PID" 2>/dev/null || fail "anvil exited: $(cat "$TMP/anvil.log")"
  sleep 1
done
assert_eq "chain id" "$(cast chain-id --rpc-url "$LOCAL")" 8453
assert_eq "wrapper asset" "$(call "$VAULT" "asset()(address)")" "$USDC"

# --- a fresh SmartVault from the real factory -----------------------------------------------------------------------
step "fresh SmartVault through the real factory"
signer_slot="0x000000000000000000000000${OWNER:2}"
signers="[($signer_slot,$ZERO32)]"
ACCOUNT="$(cast call "$FACTORY" "getAddress(address,(bytes32,bytes32)[],uint8,uint256)(address)" "$OWNER" "$signers" 1 8453 --rpc-url "$LOCAL")"
cast send "$FACTORY" "createAccount(address,(bytes32,bytes32)[],uint8,uint256)" "$OWNER" "$signers" 1 8453 \
  --private-key "$DEPLOYER_KEY" --rpc-url "$LOCAL" >/dev/null
[[ "$(cast code "$ACCOUNT" --rpc-url "$LOCAL")" != "0x" ]] || fail "account has no code"
echo_ok "account $ACCOUNT"

rpc anvil_impersonateAccount "$ACCOUNT"
rpc anvil_setBalance "$ACCOUNT" 0x8ac7230489e80000 # 10 ETH for the impersonated account's gas
as_account() { cast send "$@" --from "$ACCOUNT" --unlocked --rpc-url "$LOCAL" >/dev/null; }

# USDC balances live in `balanceAndBlacklistStates` (slot 9); bit 255 is the blacklist flag.
set_usdc_balance() { rpc anvil_setStorageAt "$USDC" "$(cast index address "$1" 9)" "$(cast to-uint256 "$2")"; }
blacklist() { rpc anvil_setStorageAt "$USDC" "$(cast index address "$1" 9)" "$(printf '0x8%063x' 0)"; }
deposit_as_account() {
  set_usdc_balance "$ACCOUNT" "$1"
  as_account "$USDC" "approve(address,uint256)" "$VAULT" "$1"
  as_account "$VAULT" "deposit(uint256,address)" "$1" "$ACCOUNT"
}
position() { call "$VAULT" "convertToAssets(uint256)(uint256)" "$(call "$VAULT" "balanceOf(address)(uint256)" "$ACCOUNT")"; }

expect_deploy_revert() { # expect_deploy_revert <message fragment> [VAR=value...]: a dry run that must revert
  local fragment="$1"
  shift
  if env "$@" forge script script/DeployYieldSkimmer.s.sol --rpc-url "$LOCAL" >"$TMP/neg.log" 2>&1; then
    fail "deploy script should have reverted with '$fragment'"
  fi
  grep -q -- "$fragment" "$TMP/neg.log" || {
    cat "$TMP/neg.log"
    fail "deploy script reverted without '$fragment'"
  }
  echo_ok "deploy script refuses: $fragment"
}

step "deploy script sanity checks refuse a wrong setup"
expect_deploy_revert "ACCOUNT has no code" ACCOUNT="$(cast wallet new --json | jq -r '.[0].address')"
expect_deploy_revert "does not answer isModuleEnabled" ACCOUNT="$VAULT" # a contract that is not a SmartVault
expect_deploy_revert "ACCOUNT holds no VAULT shares" ACCOUNT="$ACCOUNT" # nothing deposited yet
expect_deploy_revert "VAULT.asset() is" ACCOUNT="$ACCOUNT" ASSET=0x4200000000000000000000000000000000000006
expect_deploy_revert "CAP_BPS must be" ACCOUNT="$ACCOUNT" CAP_BPS=0

# --- rollout step 1: the no-op module -------------------------------------------------------------------------------
step "forge script script/DeployNoopModule.s.sol: enable and disable with the printed calldata"
ACCOUNT="$ACCOUNT" forge script script/DeployNoopModule.s.sol --rpc-url "$LOCAL" --broadcast \
  --private-key "$DEPLOYER_KEY" >"$TMP/noop.log" 2>&1 || {
  cat "$TMP/noop.log"
  fail "noop deploy script failed"
}
NOOP="$(grep -E '^ *NoopModule: 0x' "$TMP/noop.log" | awk '{print $2}')"
NOOP_ENABLE="$(grep -E '^ *enableModule calldata: 0x' "$TMP/noop.log" | awk '{print $3}')"
NOOP_DISABLE="$(grep -E '^ *disableModule calldata: 0x' "$TMP/noop.log" | awk '{print $3}')"
[[ -n "$NOOP" && -n "$NOOP_ENABLE" && -n "$NOOP_DISABLE" ]] || fail "could not parse the noop script output"
[[ "$(cast code "$NOOP" --rpc-url "$LOCAL")" != "0x" ]] || fail "NoopModule has no code"
as_account "$ACCOUNT" "$NOOP_ENABLE"
assert_eq "noop enabled" "$(call "$ACCOUNT" "isModuleEnabled(address)(bool)" "$NOOP")" true
as_account "$ACCOUNT" "$NOOP_DISABLE"
assert_eq "noop disabled" "$(call "$ACCOUNT" "isModuleEnabled(address)(bool)" "$NOOP")" false
echo_ok "NoopModule $NOOP enabled and disabled by self-call"

deposit_as_account "$DEPOSIT"
echo_ok "deposited; position=$(position)"

# --- deploy through the real script ---------------------------------------------------------------------------------
step "forge script script/DeployYieldSkimmer.s.sol (CREATE2, against the fork)"
ACCOUNT="$ACCOUNT" forge script script/DeployYieldSkimmer.s.sol --rpc-url "$LOCAL" --broadcast \
  --private-key "$DEPLOYER_KEY" >"$TMP/deploy.log" 2>&1 || {
  cat "$TMP/deploy.log"
  fail "deploy script failed"
}
SKIMMER="$(grep -E '^ *YieldSkimmer: 0x' "$TMP/deploy.log" | awk '{print $2}')"
PREDICTED="$(grep -E '^ *Predicted YieldSkimmer: 0x' "$TMP/deploy.log" | awk '{print $3}')"
ENABLE_DATA="$(grep -E '^ *enableModule calldata: 0x' "$TMP/deploy.log" | awk '{print $3}')"
DISABLE_DATA="$(grep -E '^ *disableModule calldata: 0x' "$TMP/deploy.log" | awk '{print $3}')"
[[ -n "$SKIMMER" && -n "$ENABLE_DATA" && -n "$DISABLE_DATA" ]] || {
  cat "$TMP/deploy.log"
  fail "could not parse the deploy script output"
}
assert_eq "deployed == predicted" "$SKIMMER" "$PREDICTED"
assert_eq "enable calldata" "$ENABLE_DATA" "$(cast calldata "enableModule(address)" "$SKIMMER")"
assert_eq "disable calldata" "$DISABLE_DATA" "$(cast calldata "disableModule(address)" "$SKIMMER")"
assert_eq "skimmer.account" "$(call "$SKIMMER" "account()(address)")" "$ACCOUNT"
# A fresh factory account proxies the known implementation but has no auto-earn: exactly that one warning.
assert_eq "warnings" "$(grep -c -E '^ *WARNING' "$TMP/deploy.log")" 1
assert_contains "warnings" "$(grep -E '^ *WARNING' "$TMP/deploy.log")" "AutoEarnModuleV2 is not enabled"
if [[ "${VERBOSE:-}" == "1" ]]; then cat "$TMP/deploy.log"; else
  grep -E '^ *(YieldSkimmer:|enableModule calldata:)' "$TMP/deploy.log"
fi
echo_ok "skimmer $SKIMMER"

# Re-running is idempotent: same address, no second deploy.
ACCOUNT="$ACCOUNT" forge script script/DeployYieldSkimmer.s.sol --rpc-url "$LOCAL" --broadcast \
  --private-key "$DEPLOYER_KEY" >"$TMP/deploy2.log" 2>&1 || fail "second deploy run failed"
assert_contains "second deploy run" "$(cat "$TMP/deploy2.log")" "Already deployed"
echo_ok "second run skipped the deploy"

# --- enable with the printed calldata, add recipients ---------------------------------------------------------------
step "enable the module (printed calldata, self-call) and add two recipients"
assert_eq "enabled before" "$(call "$ACCOUNT" "isModuleEnabled(address)(bool)" "$SKIMMER")" false
as_account "$ACCOUNT" "$ENABLE_DATA"
assert_eq "enabled after" "$(call "$ACCOUNT" "isModuleEnabled(address)(bool)" "$SKIMMER")" true
as_account "$SKIMMER" "addRecipient(address,uint16,uint32)" "$BAD_RECIPIENT" 2000 0
as_account "$SKIMMER" "addRecipient(address,uint16,uint32)" "$GOOD_RECIPIENT" 3000 0
blacklist "$BAD_RECIPIENT"
assert_eq "recipientCount" "$(call "$SKIMMER" "recipientCount()(uint256)")" 2
echo_ok "module enabled; recipients added (bad one first, blacklisted in USDC)"

run_keeper() { # run_keeper [env assignments...]; sets KEEPER_OUT and KEEPER_RC
  set +e
  KEEPER_OUT="$(env SKIMMER="$SKIMMER" RPC_URL="$LOCAL" KEEPER_PRIVATE_KEY="$KEEPER_KEY" "$@" ops/keeper.sh 2>&1)"
  KEEPER_RC=$?
  set -e
  printf '%s\n' "$KEEPER_OUT" | sed 's/^/    | /'
}
nonce() { cast nonce "$KEEPER_ADDR" --rpc-url "$LOCAL"; }

# --- run 1: initialize ----------------------------------------------------------------------------------------------
step "keeper run 1 (lastSkim == 0: initializes the watermark)"
run_keeper
assert_eq "run 1 exit" "$KEEPER_RC" 0
assert_contains "run 1" "$KEEPER_OUT" "skim: ok"
assert_gt "lastSkim set" "$(call "$SKIMMER" "lastSkim()(uint256)")" 0
assert_near "principal ~ position" "$(call "$SKIMMER" "principal()(uint256)")" "$(position)" 1000000
assert_contains "run 1 pulls" "$KEEPER_OUT" "nothing accrued"
echo_ok "initialized; principal == position == $(position)"

# --- yield ----------------------------------------------------------------------------------------------------------
step "30 days later"
rpc anvil_increaseTime 2592000
rpc anvil_mine 1
read -r _ take <<<"$(cast call "$SKIMMER" "previewSkim()(uint256,uint256)" --rpc-url "$LOCAL" | awk '{print $1}' | paste -sd' ' -)"
if [[ "$take" != "0" && "${SIMULATE_YIELD:-}" != "1" ]]; then
  YIELD_SOURCE="real Morpho interest after anvil_increaseTime"
else
  # VaultV2 interest did not move on this fork (or SIMULATE_YIELD=1). Prove the mechanics anyway: a 20 USDC deposit
  # the account did not announce sits above the watermark and under the rate ceiling, so it counts as yield.
  deposit_as_account 20000000
  YIELD_SOURCE="simulated: unannounced 20 USDC deposit"
fi
read -r yield_amt take <<<"$(cast call "$SKIMMER" "previewSkim()(uint256,uint256)" --rpc-url "$LOCAL" | awk '{print $1}' | paste -sd' ' -)"
assert_gt "previewSkim take" "$take" 0
echo_ok "yield source: $YIELD_SOURCE; previewSkim yieldAmt=$yield_amt take=$take"

# --- DRY_RUN sends nothing ------------------------------------------------------------------------------------------
step "keeper DRY_RUN=1 (prints the command, sends nothing)"
nonce_before="$(nonce)"
run_keeper DRY_RUN=1 KEEPER_PRIVATE_KEY=
assert_eq "dry run exit" "$KEEPER_RC" 0
assert_contains "dry run" "$KEEPER_OUT" 'DRY_RUN: cast send'
assert_eq "dry run nonce" "$(nonce)" "$nonce_before"
echo_ok "no transaction sent"

# --- paused ---------------------------------------------------------------------------------------------------------
step "keeper while paused (logs and exits 0)"
as_account "$SKIMMER" "pause()"
run_keeper
assert_eq "paused exit" "$KEEPER_RC" 0
assert_contains "paused" "$KEEPER_OUT" "paused"
assert_eq "paused nonce" "$(nonce)" "$nonce_before"
as_account "$SKIMMER" "unpause()"
echo_ok "paused: exit 0, nothing sent"

# --- run 2: skim and pull, one recipient's pull fails ---------------------------------------------------------------
step "keeper run 2 (skim, then pull both; the blacklisted recipient's pull fails)"
good_before="$(call "$USDC" "balanceOf(address)(uint256)" "$GOOD_RECIPIENT")"
assert_eq "good recipient starts empty" "$good_before" 0
run_keeper
assert_eq "run 2 exit (a failed pull must not fail the run)" "$KEEPER_RC" 0
assert_contains "run 2 skim" "$KEEPER_OUT" "skim: ok"
assert_contains "run 2 good pull" "$KEEPER_OUT" "pull($GOOD_RECIPIENT): ok"
assert_contains "run 2 bad pull" "$KEEPER_OUT" "pull($BAD_RECIPIENT): send failed"
assert_contains "run 2 summary" "$KEEPER_OUT" "pulls_ok=1 pulls_failed=1"
assert_eq "good accrued" "$(call "$SKIMMER" "accrued(address)(uint256)" "$GOOD_RECIPIENT")" 0
good_after="$(call "$USDC" "balanceOf(address)(uint256)" "$GOOD_RECIPIENT")"
assert_gt "good recipient USDC rose" "$good_after" "$good_before"
assert_gt "bad accrued stays" "$(call "$SKIMMER" "accrued(address)(uint256)" "$BAD_RECIPIENT")" 0
assert_eq "bad balance" "$(call "$USDC" "balanceOf(address)(uint256)" "$BAD_RECIPIENT")" 0
# principal was set to the position inside the skim; the position keeps earning interest in the blocks since.
assert_near "principal ~ position after skim" "$(call "$SKIMMER" "principal()(uint256)")" "$(position)" 1000000
echo_ok "good recipient: $good_before -> $good_after USDC wei; accrued 0. Bad recipient still owed, run exited 0"

# --- nothing to skim: no transaction ---------------------------------------------------------------------------------
step "keeper when previewSkim take is 0 (absoluteMaxPerSkim set to 0): skip skim, send nothing"
as_account "$SKIMMER" "setCap(uint16,uint256)" 3000 0
nonce_before="$(nonce)"
run_keeper
assert_eq "skip exit" "$KEEPER_RC" 0
assert_contains "skip skim" "$KEEPER_OUT" "skip skim: previewSkim take is 0"
assert_eq "skip nonce" "$(nonce)" "$nonce_before"
as_account "$SKIMMER" "setCap(uint16,uint256)" 3000 50000000
echo_ok "skim skipped, no transaction"

# --- a failing skim fails the run -----------------------------------------------------------------------------------
step "keeper with an unfunded key (skim() cannot be sent: the run must exit non-zero)"
rpc anvil_increaseTime 86400
rpc anvil_mine 1
read -r _ take <<<"$(cast call "$SKIMMER" "previewSkim()(uint256,uint256)" --rpc-url "$LOCAL" | awk '{print $1}' | paste -sd' ' -)"
if [[ "$take" == "0" ]]; then deposit_as_account 5000000; fi
unfunded_key="$(cast wallet new --json | jq -r '.[0].private_key')"
run_keeper KEEPER_PRIVATE_KEY="$unfunded_key"
((KEEPER_RC != 0)) || fail "expected a non-zero exit when skim() cannot be sent"
assert_contains "failed skim" "$KEEPER_OUT" "skim: send failed"
echo_ok "exit $KEEPER_RC"

printf '\nALL KEEPER TESTS PASSED (yield: %s)\n' "$YIELD_SOURCE"
