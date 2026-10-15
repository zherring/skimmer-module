#!/usr/bin/env bash
# Integration test for sign-as-account.mjs and glider-enroll.mjs on an anvil fork of Base.
#
# Creates fresh Splits SmartVaults through the real factory, signs a synthetic Glider-shaped
# EIP-712 payload as each vault, and checks the result three independent ways: the tool's own
# on-chain verification, `cast call isValidSignature`, and hashes recomputed with cast/keccak
# (no viem). Also covers the negative paths and glider-enroll (--dry-run, plus the live path
# against a local mock of Glider's two endpoints; Glider itself is never contacted).
#
# Needs: node >= 20, anvil, cast, jq, curl. Run `npm ci` first.
# Env:   BASE_RPC_URL (default https://mainnet.base.org). Keep fork traffic small: public RPCs rate-limit.
#
# The signer keys below are anvil's publicly documented dev keys. They are only ever passed through
# the environment and are never echoed; the last step greps all captured output to prove it.

set -euo pipefail
set +x # never trace: later commands carry key material

cd "$(dirname "${BASH_SOURCE[0]}")"
HERE=$PWD

BASE_RPC_URL=${BASE_RPC_URL:-https://mainnet.base.org}
FACTORY=0x8E6Af8Ed94E87B4402D0272C5D6b0D47F0483e7C
CHAIN_ID=8453
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
MAGIC=0x1626ba7e

# anvil default accounts 0..2 (addresses are public; keys come from the environment only)
ADDR0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ADDR1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
ADDR2=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
export TEST_KEY0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export TEST_KEY1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
export TEST_KEY2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
DEPLOYER=$ADDR0

for bin in node anvil cast jq curl; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 2; }
done
[ -d node_modules/viem ] || { echo "run 'npm ci' in $HERE first" >&2; exit 2; }

TMP=$(mktemp -d)
LOG=$TMP/all-output.log
: >"$LOG"
ANVIL_PID=""
MOCK_PID=""
cleanup() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
  [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

PASS=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() {
  printf '  FAIL %s\n' "$1" >&2
  [ -n "${2:-}" ] && printf '       %s\n' "$2" >&2
  exit 1
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
assert_eq() { if [ "$(lower "$2")" = "$(lower "$3")" ]; then ok "$1 ($2)"; else bad "$1" "got: $2  want: $3"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
assert_fails() { # name rc stderr [expected substring]
  if [ "$2" -eq 0 ]; then bad "$1" "expected a non-zero exit, got 0"; fi
  if [ -n "${4:-}" ]; then
    case "$3" in *"$4"*) ;; *) bad "$1" "stderr lacks '$4': $3" ;; esac
  fi
  ok "$1 (exit $2)"
}

# run a command, capturing stdout/stderr/exit code without tripping `set -e`
run() {
  set +e
  OUT=$("$@" 2>"$TMP/err")
  RC=$?
  set -e
  ERR=$(cat "$TMP/err")
  printf '%s\n%s\n' "$OUT" "$ERR" >>"$LOG"
}
sign() { run node "$HERE/sign-as-account.mjs" --rpc "$RPC" "$@"; }

on_chain_check() { # vault hash sig -> bytes4, or "revert"
  local r
  if r=$(cast call "$1" "isValidSignature(bytes32,bytes)(bytes4)" "$2" "$3" --rpc-url "$RPC" 2>/dev/null); then
    printf '%s' "$r"
  else
    printf 'revert'
  fi
}

# ---- independent EIP-712 maths (cast only, no viem) ----------------------------------------
DOMAIN_TYPE="EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
domain_sep() { # name version chainId verifyingContract
  cast keccak "$(cast abi-encode 'f(bytes32,bytes32,bytes32,uint256,address)' \
    "$(cast keccak "$DOMAIN_TYPE")" "$(cast keccak "$1")" "$(cast keccak "$2")" "$3" "$4")"
}
digest() { cast keccak "$(cast concat-hex 0x1901 "$1" "$2")"; } # domainSeparator structHash
VERIFYING=0x9999999999999999999999999999999999999999
NONCE=7
EXPIRY=1893456000
ext_hash() { # account -> EIP-712 hash of the synthetic payload
  digest "$(domain_sep GliderEnroll 1 "$CHAIN_ID" "$VERIFYING")" \
    "$(cast keccak "$(cast abi-encode 'f(bytes32,address,uint256,uint256)' \
      "$(cast keccak 'Enrollment(address account,uint256 nonce,uint256 expiry)')" "$1" "$NONCE" "$EXPIRY")")"
}
wrap_hash() { # vault hash -> SplitMessage wrap, i.e. what the signers sign
  digest "$(domain_sep splitsSmartVault 1 "$CHAIN_ID" "$1")" \
    "$(cast keccak "$(cast abi-encode 'f(bytes32,bytes32)' "$(cast keccak 'SplitMessage(bytes32 hash)')" "$2")")"
}
write_payload() { # account file
  cat >"$2" <<EOF
{
  "domain": { "name": "GliderEnroll", "version": "1", "chainId": $CHAIN_ID, "verifyingContract": "$VERIFYING" },
  "types": {
    "Enrollment": [
      { "name": "account", "type": "address" },
      { "name": "nonce", "type": "uint256" },
      { "name": "expiry", "type": "uint256" }
    ]
  },
  "primaryType": "Enrollment",
  "message": { "account": "$1", "nonce": "$NONCE", "expiry": $EXPIRY }
}
EOF
}

eoa_signer() { printf '%s,%s' "$(cast pad "$1" --left --len 32)" "$ZERO32"; }
create_vault() { # salt threshold signer... -> vault address ("slot1,slot2" per signer)
  local salt=$1 threshold=$2 signers="" s addr
  shift 2
  for s in "$@"; do signers="$signers${signers:+,}($s)"; done
  signers="[$signers]"
  addr=$(cast call "$FACTORY" "getAddress(address,(bytes32,bytes32)[],uint8,uint256)(address)" \
    "$DEPLOYER" "$signers" "$threshold" "$salt" --rpc-url "$RPC")
  cast send "$FACTORY" "createAccount(address,(bytes32,bytes32)[],uint8,uint256)" \
    "$DEPLOYER" "$signers" "$threshold" "$salt" --unlocked --from "$DEPLOYER" --rpc-url "$RPC" >/dev/null
  [ "$(cast code "$addr" --rpc-url "$RPC")" != 0x ] || bad "vault deployed at $addr"
  printf '%s' "$addr"
}

free_port() { node --input-type=module -e "import n from 'node:net';const s=n.createServer().listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close()})"; }

# ---- 0. static checks ----------------------------------------------------------------------
echo "== static checks"
for f in sign-as-account.mjs glider-enroll.mjs mock-glider.mjs; do node --check "$f"; done
ok "node --check on all scripts"

# ---- 1. fork --------------------------------------------------------------------------------
echo "== anvil fork of Base ($CHAIN_ID)"
ANVIL_PORT=$(free_port)
MOCK_PORT=$(free_port)
RPC=http://127.0.0.1:$ANVIL_PORT
anvil --fork-url "$BASE_RPC_URL" --chain-id "$CHAIN_ID" --port "$ANVIL_PORT" --silent \
  --retries 10 --fork-retry-backoff 2000 >"$TMP/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 60); do
  cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
  kill -0 "$ANVIL_PID" 2>/dev/null || { cat "$TMP/anvil.log" >&2; bad "anvil exited early"; }
  sleep 1
done
assert_eq "fork chain id" "$(cast chain-id --rpc-url "$RPC")" "$CHAIN_ID"

# ---- 2. vaults through the real factory -----------------------------------------------------
echo "== vaults via factory $FACTORY"
VAULT_A=$(create_vault 1 1 "$(eoa_signer $ADDR0)")
VAULT_B=$(create_vault 2 2 "$(eoa_signer $ADDR0)" "$(eoa_signer $ADDR1)")
VAULT_C=$(create_vault 3 2 "$(eoa_signer $ADDR0)" "$(eoa_signer $ADDR1)" "$(eoa_signer $ADDR2)")
# a passkey signer at index 1 (slot2 != 0); coordinates are dummies, it is never exercised
PASSKEY="0x1111111111111111111111111111111111111111111111111111111111111111,0x2222222222222222222222222222222222222222222222222222222222222222"
VAULT_D=$(create_vault 4 1 "$(eoa_signer $ADDR0)" "$PASSKEY")
assert_eq "vault A threshold" "$(cast call "$VAULT_A" 'getThreshold()(uint8)' --rpc-url "$RPC")" 1
assert_eq "vault B threshold" "$(cast call "$VAULT_B" 'getThreshold()(uint8)' --rpc-url "$RPC")" 2
assert_eq "vault C signer count" "$(cast call "$VAULT_C" 'getSignerCount()(uint8)' --rpc-url "$RPC")" 3
echo "   A=$VAULT_A (1 of 1)  B=$VAULT_B (2 of 2)  C=$VAULT_C (2 of 3)  D=$VAULT_D (passkey at 1)"

# ---- 3. threshold 1 -------------------------------------------------------------------------
echo "== (a) threshold 1, one EOA signer"
write_payload "$VAULT_A" "$TMP/payload-a.json"
sign --vault "$VAULT_A" --typed-data "$TMP/payload-a.json" --key 0:env:TEST_KEY0
[ "$RC" -eq 0 ] || bad "sign as vault A" "$ERR"
ok "exit 0"
assert_eq "verified flag" "$(jq -r .verified <<<"$OUT")" true
assert_eq "signer 0 address" "$(jq -r '.signers[0].address' <<<"$OUT")" "$ADDR0"
HASH_A=$(jq -r .hash <<<"$OUT")
SIG_A=$(jq -r .signature <<<"$OUT")
assert_eq "hash == independent EIP-712 hash (cast)" "$HASH_A" "$(ext_hash "$VAULT_A")"
assert_eq "local W == independent wrap (cast keccak)" "$(jq -r .replaySafeHash <<<"$OUT")" "$(wrap_hash "$VAULT_A" "$HASH_A")"
assert_eq "local W == vault.replaySafeHash (cast call)" "$(jq -r .replaySafeHash <<<"$OUT")" \
  "$(cast call "$VAULT_A" 'replaySafeHash(bytes32)(bytes32)' "$HASH_A" --rpc-url "$RPC")"
assert_eq "cast call isValidSignature" "$(on_chain_check "$VAULT_A" "$HASH_A" "$SIG_A")" "$MAGIC"

echo "== (a) negative: tampered, wrong message, wrong key, bad index, bad vault"
# first wrapper's signatureData starts at byte 224 for a 1-signature blob; flip a nibble inside r
POS=$((2 + 2 * 224 + 10))
CUR=${SIG_A:$POS:1}
if [ "$CUR" = a ]; then NEW=b; else NEW=a; fi
TAMPERED="${SIG_A:0:$POS}$NEW${SIG_A:$((POS + 1))}"
[ "$TAMPERED" != "$SIG_A" ] || bad "tamper changed the signature"
R=$(on_chain_check "$VAULT_A" "$HASH_A" "$TAMPERED")
if [ "$R" = "$MAGIC" ]; then bad "tampered signature must not validate"; else ok "tampered signature rejected on-chain ($R)"; fi
OTHER_HASH=$(cast keccak "some other message")
R=$(on_chain_check "$VAULT_A" "$OTHER_HASH" "$SIG_A")
if [ "$R" = "$MAGIC" ]; then bad "signature must not validate for a different hash"; else ok "same signature, different hash rejected ($R)"; fi

sign --vault "$VAULT_A" --typed-data "$TMP/payload-a.json" --key 0:env:TEST_KEY1
assert_fails "wrong key for index 0" "$RC" "$ERR" "derives"
if [ -z "$OUT" ]; then ok "nothing printed to stdout on failure"; else bad "stdout must stay empty on failure" "$OUT"; fi
sign --vault "$VAULT_A" --typed-data "$TMP/payload-a.json" --key 3:env:TEST_KEY0
assert_fails "no signer at index 3" "$RC" "$ERR" "no signer registered at index 3"
sign --vault "$VAULT_A" --typed-data "$TMP/payload-a.json" --key 0:env:TEST_KEY0 --key 0:env:TEST_KEY0
assert_fails "duplicate index" "$RC" "$ERR" "more than once"
sign --vault "$VAULT_A" --typed-data "$TMP/payload-a.json" --key 0:env:TEST_KEY0 --threshold-override 2
assert_fails "--threshold-override 2 with one key" "$RC" "$ERR" "requires 2"
sign --vault "$VAULT_A" --typed-data "$TMP/payload-a.json" --key 0:env:NO_SUCH_VAR_FOR_TEST
assert_fails "unset env var for key" "$RC" "$ERR" "NO_SUCH_VAR_FOR_TEST is not set"
sign --vault "$VAULT_A" --typed-data "$TMP/payload-a.json" --key "0:$TEST_KEY0"
if [ "$RC" -eq 0 ]; then ok "literal --key <index>:<0xkey> form accepted"; else bad "literal key form" "$ERR"; fi
# (anvil's dev addresses carry EIP-7702 delegations on some chains, so use a hash-derived address)
NOCODE=0x$(cast keccak "sign-as-account: an address with no code" | cut -c27-66)
assert_eq "test address really has no code" "$(cast code "$NOCODE" --rpc-url "$RPC")" 0x
sign --vault "$NOCODE" --typed-data "$TMP/payload-a.json" --key 0:env:TEST_KEY1
assert_fails "vault address with no code" "$RC" "$ERR" "no contract code"
sign --vault 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 --typed-data "$TMP/payload-a.json" --key 0:env:TEST_KEY0
assert_fails "contract that is not a Splits SmartVault (USDC)" "$RC" "$ERR" "SmartVault"

# ---- 4. threshold 2 -------------------------------------------------------------------------
echo "== (b) threshold 2, two EOA signers"
write_payload "$VAULT_B" "$TMP/payload-b.json"
# keys given out of order on purpose: the tool sorts by index; order is irrelevant to the vault
sign --vault "$VAULT_B" --typed-data "$TMP/payload-b.json" --key 1:env:TEST_KEY1 --key 0:env:TEST_KEY0
[ "$RC" -eq 0 ] || bad "sign as vault B" "$ERR"
ok "exit 0"
assert_eq "verified flag" "$(jq -r .verified <<<"$OUT")" true
assert_eq "two signers, indices" "$(jq -c '[.signers[].index]' <<<"$OUT")" "[0,1]"
HASH_B=$(jq -r .hash <<<"$OUT")
SIG_B=$(jq -r .signature <<<"$OUT")
assert_eq "hash == independent EIP-712 hash (cast)" "$HASH_B" "$(ext_hash "$VAULT_B")"
assert_eq "local W == independent wrap (cast keccak)" "$(jq -r .replaySafeHash <<<"$OUT")" "$(wrap_hash "$VAULT_B" "$HASH_B")"
assert_eq "local W == vault.replaySafeHash (cast call)" "$(jq -r .replaySafeHash <<<"$OUT")" \
  "$(cast call "$VAULT_B" 'replaySafeHash(bytes32)(bytes32)' "$HASH_B" --rpc-url "$RPC")"
assert_eq "cast call isValidSignature" "$(on_chain_check "$VAULT_B" "$HASH_B" "$SIG_B")" "$MAGIC"

echo "== (b) negative"
sign --vault "$VAULT_B" --typed-data "$TMP/payload-b.json" --key 0:env:TEST_KEY0
assert_fails "threshold 2 with one key" "$RC" "$ERR" "requires 2"
sign --vault "$VAULT_B" --typed-data "$TMP/payload-b.json" --key 0:env:TEST_KEY0 --threshold-override 1
assert_fails "one key + --threshold-override 1 is still caught by on-chain verification" "$RC" "$ERR" "isValidSignature"
sign --vault "$VAULT_B" --typed-data "$TMP/payload-b.json" --key 0:env:TEST_KEY0 --key 1:env:TEST_KEY2
assert_fails "wrong key for index 1" "$RC" "$ERR" "derives"
# first wrapper's signatureData starts at byte 256 for a 2-signature blob
POS=$((2 + 2 * 256 + 10))
CUR=${SIG_B:$POS:1}
if [ "$CUR" = a ]; then NEW=b; else NEW=a; fi
TAMPERED="${SIG_B:0:$POS}$NEW${SIG_B:$((POS + 1))}"
R=$(on_chain_check "$VAULT_B" "$HASH_B" "$TAMPERED")
if [ "$R" = "$MAGIC" ]; then bad "tampered 2-of-2 signature must not validate"; else ok "tampered signature rejected on-chain ($R)"; fi

echo "== (c) 2 of 3: a non-contiguous subset (indices 0 and 2)"
write_payload "$VAULT_C" "$TMP/payload-c.json"
sign --vault "$VAULT_C" --typed-data "$TMP/payload-c.json" --key 2:env:TEST_KEY2 --key 0:env:TEST_KEY0
[ "$RC" -eq 0 ] || bad "sign as vault C" "$ERR"
assert_eq "cast call isValidSignature" "$(on_chain_check "$VAULT_C" "$(jq -r .hash <<<"$OUT")" "$(jq -r .signature <<<"$OUT")")" "$MAGIC"

echo "== (d) passkey signer is detected and refused"
write_payload "$VAULT_D" "$TMP/payload-d.json"
sign --vault "$VAULT_D" --typed-data "$TMP/payload-d.json" --key 1:env:TEST_KEY1
assert_fails "passkey slot" "$RC" "$ERR" "passkey"
sign --vault "$VAULT_D" --typed-data "$TMP/payload-d.json" --key 0:env:TEST_KEY0
if [ "$RC" -eq 0 ]; then ok "the EOA slot of the same vault still signs"; else bad "EOA slot beside a passkey" "$ERR"; fi

# ---- 4b. a Glider-withdrawal-shaped payload: strings, a struct array, bytes32, a numeric uint256 ----
echo "== (e) withdrawal-shaped payload (nested struct array) signed as vault A"
WD_PORTFOLIO=a1b2c3d4
WD_RECIPIENT=eip155:8453:0x4444444444444444444444444444444444444444
WD_ASSET=eip155:8453/erc20:0x833589fcd6edb6e08f4c7c32d4f71b54bda02913
WD_AMOUNT=1000500000
WD_NONCE=0x00000000000000000000000000000000000000000000000000000000deadbeef
WD_EXPIRES=1776384600
cat >"$TMP/payload-wd.json" <<EOF
{
  "primaryType": "Withdrawal",
  "domain": { "name": "Glider Withdrawal Authorization", "version": "1", "chainId": $CHAIN_ID,
              "verifyingContract": "0x2222222222222222222222222222222222222222" },
  "types": {
    "Withdrawal": [
      { "name": "portfolioId", "type": "string" },
      { "name": "recipientAccountId", "type": "string" },
      { "name": "assets", "type": "WithdrawalAsset[]" },
      { "name": "nonce", "type": "bytes32" },
      { "name": "expiresAt", "type": "uint256" }
    ],
    "WithdrawalAsset": [
      { "name": "assetId", "type": "string" },
      { "name": "amountRaw", "type": "string" }
    ]
  },
  "message": {
    "portfolioId": "$WD_PORTFOLIO",
    "recipientAccountId": "$WD_RECIPIENT",
    "assets": [ { "assetId": "$WD_ASSET", "amountRaw": "$WD_AMOUNT" } ],
    "nonce": "$WD_NONCE",
    "expiresAt": $WD_EXPIRES
  }
}
EOF
ASSET_STRUCT=$(cast keccak "$(cast abi-encode 'f(bytes32,bytes32,bytes32)' \
  "$(cast keccak 'WithdrawalAsset(string assetId,string amountRaw)')" "$(cast keccak "$WD_ASSET")" "$(cast keccak "$WD_AMOUNT")")")
WD_STRUCT=$(cast keccak "$(cast abi-encode 'f(bytes32,bytes32,bytes32,bytes32,bytes32,uint256)' \
  "$(cast keccak 'Withdrawal(string portfolioId,string recipientAccountId,WithdrawalAsset[] assets,bytes32 nonce,uint256 expiresAt)WithdrawalAsset(string assetId,string amountRaw)')" \
  "$(cast keccak "$WD_PORTFOLIO")" "$(cast keccak "$WD_RECIPIENT")" "$(cast keccak "$ASSET_STRUCT")" "$WD_NONCE" "$WD_EXPIRES")")
WD_HASH=$(digest "$(domain_sep 'Glider Withdrawal Authorization' 1 "$CHAIN_ID" 0x2222222222222222222222222222222222222222)" "$WD_STRUCT")
sign --vault "$VAULT_A" --typed-data "$TMP/payload-wd.json" --key 0:env:TEST_KEY0
[ "$RC" -eq 0 ] || bad "sign withdrawal-shaped payload" "$ERR"
assert_eq "hash == independent EIP-712 hash (cast)" "$(jq -r .hash <<<"$OUT")" "$WD_HASH"
assert_eq "cast call isValidSignature" "$(on_chain_check "$VAULT_A" "$WD_HASH" "$(jq -r .signature <<<"$OUT")")" "$MAGIC"
# the same payload wrapped the way Glider's API envelope nests it is accepted too
jq '{success: true, data: {authorizationId: "0x01", typedData: .}}' "$TMP/payload-wd.json" >"$TMP/payload-wd-envelope.json"
sign --vault "$VAULT_A" --typed-data "$TMP/payload-wd-envelope.json" --key 0:env:TEST_KEY0
[ "$RC" -eq 0 ] || bad "sign from a saved API response envelope" "$ERR"
assert_eq "envelope input gives the same hash" "$(jq -r .hash <<<"$OUT")" "$WD_HASH"

# ---- 5. glider-enroll: dry run --------------------------------------------------------------
echo "== glider-enroll --dry-run"
CANARY=gldr_sk_canary_must_never_be_printed
export GLIDER_API_KEY=$CANARY
AGENT=eip155:0:0x1111111111111111111111111111111111111111
run node "$HERE/glider-enroll.mjs" --dry-run --typed-data "$TMP/payload-b.json" --owner "$VAULT_B" --chain 8453 \
  --strategy 01JWZEE2MF30KVRMRX53N88VA4 --rpc "$RPC" --key 0:env:TEST_KEY0 --key 1:env:TEST_KEY1 \
  --flow-id flow_test_1 --account-index 7 --agent-account-id "$AGENT" --portfolio-name "Song A Day"
[ "$RC" -eq 0 ] || bad "dry run" "$ERR"
ok "exit 0"
assert_eq "prints both curl commands" "$(printf '%s\n' "$OUT" | grep -c '^curl -sS -X POST')" 2
assert_contains "stage 1 url (default staging API)" "$OUT" "https://staging-api.glider.fi/v2/enroll/signature"
assert_contains "stage 2 url" "$OUT" "https://staging-api.glider.fi/v2/enroll'"
assert_contains "stage 1 accountType" "$OUT" '"accountType": "ERC1271"'
assert_contains "ownerAccountId is chain-agnostic CAIP-10" "$OUT" "\"ownerAccountId\": \"eip155:0:$(lower "$VAULT_B")\""
assert_contains "chainIds" "$OUT" '"chainIds": ['
assert_contains "round-trip accountIndex is a string" "$OUT" '"accountIndex": "7"'
assert_contains "flowId round-trips" "$OUT" '"flowId": "flow_test_1"'
assert_contains "signed payload" "$OUT" '"verified": true'
# shellcheck disable=SC2016 # the literal text '$GLIDER_API_KEY' is what must appear
assert_contains "api key is a shell reference" "$OUT" 'x-api-key: $GLIDER_API_KEY'
case "$OUT$ERR" in *"$CANARY"*) bad "GLIDER_API_KEY value leaked in dry run" ;; *) ok "GLIDER_API_KEY value never printed" ;; esac
DRY_SIG=$(printf '%s\n' "$OUT" | grep -o '"signature": "0x[0-9a-f]*"' | head -1 | cut -d'"' -f4)
[ -n "$DRY_SIG" ] || bad "dry run prints a signature"
ok "dry run prints a signature"
assert_eq "dry-run signature validates on-chain" "$(on_chain_check "$VAULT_B" "$(ext_hash "$VAULT_B")" "$DRY_SIG")" "$MAGIC"

run node "$HERE/glider-enroll.mjs" --dry-run --owner "$VAULT_B" --strategy 01JWZEE2MF30KVRMRX53N88VA4
[ "$RC" -eq 0 ] || bad "dry run without typed data" "$ERR"
assert_contains "dry run without --typed-data still prints stage 1" "$OUT" "/enroll/signature"
assert_contains "and a stage 2 template" "$OUT" "<signature from sign-as-account.mjs>"

# ---- 6. glider-enroll: live path against a local mock of Glider -----------------------------
echo "== glider-enroll live path (local mock; Glider is never contacted)"
node "$HERE/mock-glider.mjs" --port "$MOCK_PORT" --rpc "$RPC" >"$TMP/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$MOCK_PORT/v2/enroll" 2>/dev/null)" != 000 ] && break
  sleep 0.5
done
API=http://127.0.0.1:$MOCK_PORT/v2
export GLIDER_API_KEY=mock-key
run node "$HERE/glider-enroll.mjs" --api "$API" --owner "$VAULT_B" --chain 8453 --strategy 01JWZEE2MF30KVRMRX53N88VA4 \
  --rpc "$RPC" --key 0:env:TEST_KEY0 --key 1:env:TEST_KEY1 --portfolio-name "Song A Day"
[ "$RC" -eq 0 ] || bad "live enrollment against mock" "$ERR"
ok "exit 0 (stage 1, sign, stage 2; the mock re-verified the signature with isValidSignature)"
assert_contains "smartAccounts[] printed" "$OUT" '"smartAccounts"'
SMART=$(jq -r .smartAccount <<<"$OUT")
case "$SMART" in eip155:8453:0x*) ok "eip155:8453 address returned ($SMART)" ;; *) bad "eip155:8453 account" "$OUT" ;; esac

run node "$HERE/glider-enroll.mjs" --api "$API" --owner "$VAULT_B" --chain 8453 --strategy S --rpc "$RPC" \
  --key 0:env:TEST_KEY0 --key 1:env:TEST_KEY2
assert_fails "live: wrong key stops before stage 2" "$RC" "$ERR" "derives"

# --typed-data with a saved stage-1 response, then idempotent replay and conflict on flowId
curl -s -X POST "$API/enroll/signature" -H 'x-api-key: mock-key' -H 'content-type: application/json' \
  -d "{\"ownerAccountId\":\"eip155:0:$(lower "$VAULT_B")\",\"strategyId\":\"S2\",\"chainIds\":[8453],\"accountType\":\"ERC1271\"}" \
  >"$TMP/stage1.json"
FLOW=$(jq -r .data.flowId "$TMP/stage1.json")
ENROLL=(node "$HERE/glider-enroll.mjs" --api "$API" --owner "$VAULT_B" --chain 8453 --strategy S2 --rpc "$RPC"
  --key 0:env:TEST_KEY0 --key 1:env:TEST_KEY1 --typed-data "$TMP/stage1.json")
run "${ENROLL[@]}"
[ "$RC" -eq 0 ] || bad "enroll from saved stage-1 response" "$ERR"
FIRST=$OUT
assert_eq "flowId taken from the saved stage-1 response" "$(jq -r .flowId <<<"$FIRST")" "$FLOW"
run "${ENROLL[@]}"
[ "$RC" -eq 0 ] || bad "replay with the same flowId and body" "$ERR"
assert_eq "same flowId + same body replays the cached result" "$(jq -r .portfolioId <<<"$OUT")" "$(jq -r .portfolioId <<<"$FIRST")"
run "${ENROLL[@]}" --portfolio-name "different body"
assert_fails "same flowId + different body is rejected" "$RC" "$ERR" "API_008"

# ---- 7. nothing secret leaked ---------------------------------------------------------------
echo "== no key material in any captured output"
for k in "$TEST_KEY0" "$TEST_KEY1" "$TEST_KEY2" "${TEST_KEY0#0x}" "${TEST_KEY1#0x}" "${TEST_KEY2#0x}"; do
  if grep -qF "$k" "$LOG"; then bad "a private key appeared in captured output"; fi
done
ok "no private key in stdout/stderr of any run"
if grep -qF "$CANARY" "$LOG"; then bad "canary API key appeared in captured output"; else ok "no API key in stdout/stderr of any run"; fi

echo
echo "ALL TESTS PASSED ($PASS assertions)"
