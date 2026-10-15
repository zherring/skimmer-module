# sign-as-account

Sign EIP-712 typed data **as a Splits SmartVault** (ERC-1271, threshold-aware), from EOA signer keys you hold, plus a thin wrapper that uses it for Glider's two-stage enrollment.

## Why

The Glider recipient's smart account will be owned by a Splits account (`accountType: "ERC1271"`). Glider's enrollment and withdrawals return EIP-712 typed data that the owner must sign; Glider verifies it by calling `isValidSignature` on the Splits account on Base. The Splits product can only sign transaction hashes today, so this tool produces the account's ERC-1271 signature off-platform from the EOA keys registered as signers on the account.

Nothing is sent onchain. The tool only reads (`eth_call`) and signs locally.

## What it does

`sign-as-account.mjs` takes a vault, an RPC, a full EIP-712 payload and signer keys, and:

1. hashes the payload: `hash = hashTypedData(payload)`
2. computes the replay-safe wrap `W` locally and **asserts it equals `vault.replaySafeHash(hash)`** from the chain (if not, the wrap assumption is wrong and it refuses to sign)
3. reads `getThreshold()`, checks it has at least that many keys with distinct indices, and that each index is an EOA signer whose address matches the key (passkeys and contract signers are detected and refused)
4. signs `W` once per key
5. ABI-encodes the signature blob
6. calls `isValidSignature(hash, sig)` on the vault and requires `0x1626ba7e` **before printing anything**
7. prints `{ hash, replaySafeHash, signature, signers: [{index, address}], verified: true }`

On any failure it prints `error: ...` to stderr, prints nothing to stdout, and exits non-zero.

## How the SmartVault verifies (verified against the deployed source)

Implementation `0x15ec0Fa66A0D96a64d67C58368641fBE9325F3FA` on Base (chain 8453); factory `0x8E6Af8Ed94E87B4402D0272C5D6b0D47F0483e7C`.

| Fact | Detail |
| --- | --- |
| Hash is wrapped | `isValidSignature(hash, sig)` does not verify `hash` directly. It verifies `W = replaySafeHash(hash)` |
| Wrap | `W = hashTypedDataV4(SplitMessage(bytes32 hash))`, type `SplitMessage(bytes32 hash)` |
| Wrap domain | `{ name: "splitsSmartVault", version: "1", chainId, verifyingContract: <the vault proxy> }` |
| `sig` encoding | `abi.encode(ERC1271Signature)`, no type-byte prefix. `struct ERC1271Signature { SignatureWrapper[] signatures }`, `struct SignatureWrapper { uint8 signerIndex; bytes signatureData }` |
| Threshold | The first `threshold` wrappers must all verify over `W`; indices must be distinct; order does not matter; extra entries are ignored |
| Failure modes | Invalid signature returns `0xffffffff`. A duplicate or empty-slot index, or too few wrappers, **reverts** |
| EOA signer | `signatureData` is the 65-byte `r,s,v` EIP-191 signature over the 32 raw bytes of `W` (`"\x19Ethereum Signed Message:\n32" + W`). viem: `signMessage({ message: { raw: W } })`. foundry: `cast wallet sign --private-key $K <W>` |
| Signer slots | `getSigner(uint8 i) -> (bytes32 slot1, bytes32 slot2)`. `slot2 == 0` means EOA and `slot1` is the left-padded address. `slot2 != 0` means passkey (WebAuthn) |
| Signer set reads | `getThreshold()`, `getSignerCount()`, `getSigner(i)` |

Out of scope, and detected with a clear error: passkey signers, contract (nested ERC-1271) signers, and undeployed (counterfactual) vaults, which would need ERC-6492.

## Install

```sh
cd ops/sign-as-account
nvm use          # Node 22 (.nvmrc); anything >= 20 works
npm ci           # one dependency: viem, pinned
```

## sign-as-account.mjs

```sh
export SIGNER0_KEY=0x...        # prefer env: a literal key on the command line is visible in `ps`

node sign-as-account.mjs \
  --vault 0xYourSplitsAccount \
  --rpc https://mainnet.base.org \
  --typed-data payload.json \
  --key 0:env:SIGNER0_KEY \
  --key 1:env:SIGNER1_KEY        # one --key per signer slot you hold
```

| Flag | Meaning |
| --- | --- |
| `--vault <addr>` | The Splits SmartVault. Must have code. |
| `--rpc <url>` | JSON-RPC for the chain the vault lives on (Base). The wrap uses this chain's id. |
| `--typed-data <file>` | A full EIP-712 payload, exactly what a wallet's `signTypedData` takes: `{ domain, types, primaryType, message }`. A saved Glider stage-1 response (`message.typedData`) is also accepted. `uint`/`int` values may be JSON numbers or decimal/hex strings. |
| `--key <i>:<0xkey>` or `--key <i>:env:VAR` | Private key for signer slot `i`. Repeat for each signer. Keys are never logged or echoed in errors. |
| `--threshold-override <n>` | Use `n` instead of the on-chain threshold for the "enough keys" pre-check only. The final on-chain verification is still authoritative, so an override that disagrees with the vault fails there. Mostly useful to prove that. |

Output (stdout), only after the vault accepts the signature:

```json
{
  "hash": "0x7733...a888",
  "replaySafeHash": "0x9f02...2281",
  "signature": "0x0000...0000",
  "signers": [{ "index": 0, "address": "0xf39F...2266" }],
  "verified": true
}
```

`signature` is what goes to anything that calls `isValidSignature(hash, signature)` on the vault. Progress goes to stderr.

Independent check with foundry:

```sh
cast call 0xYourSplitsAccount "isValidSignature(bytes32,bytes)(bytes4)" <hash> <signature> --rpc-url https://mainnet.base.org
# 0x1626ba7e
```

## glider-enroll.mjs

Drives Glider's two-stage enrollment for a Splits account owner. Request shapes follow Glider's OpenAPI (`CreateEnrollSignatureRequest`, `CreateEnrollRequest`) and `guides/two-stage-enrollment`.

1. **Stage 1** `POST {api}/enroll/signature` with `{ ownerAccountId: "eip155:0:<vault>", strategyId, chainIds: [8453], accountType: "ERC1271" }`. The response carries `message.typedData` plus `flowId`, `accountIndex` (a string), `agentAccountId`.
2. **Sign** `message.typedData` as the vault, through the same `signAsAccount()` code path as the CLI above.
3. **Stage 2** `POST {api}/enroll` with the unchanged round-trip fields (`ownerAccountId`, `strategyId`, `chainIds`, `accountType`, `accountIndex` as a string, `agentAccountId`, `flowId`) plus `signature` (and optional `portfolioName`). It prints `portfolioId` and `smartAccounts[]`, and the `eip155:8453:0x...` account.

`flowId` is Glider's idempotency anchor (valid 24h). Retries (network errors, 5xx, 429, `API_007`) reuse the same `flowId` and the identical body, with backoff. `API_008` (same `flowId`, different body) and all 4xx errors are not retried.

```sh
export GLIDER_API_KEY=gldr_sk_...         # staging key, see the runbook
export SIGNER0_KEY=0x... SIGNER1_KEY=0x...

# 1. see exactly what would be sent, no API call
node glider-enroll.mjs --dry-run \
  --owner 0xYourSplitsAccount --strategy <strategyId> --chain 8453

# 2. for real, against staging
node glider-enroll.mjs \
  --owner 0xYourSplitsAccount --strategy <strategyId> --chain 8453 \
  --rpc https://mainnet.base.org \
  --key 0:env:SIGNER0_KEY --key 1:env:SIGNER1_KEY \
  --portfolio-name "Song A Day"
```

| Flag | Meaning |
| --- | --- |
| `--api <url>` | Default `https://staging-api.glider.fi/v2`. Production is `https://api.glider.fi/v2`. |
| `--owner <vault>` | The Splits account (also accepted as `--vault`). Sent as `eip155:0:<lowercase address>`. |
| `--chain <id>` | Default `8453`. ERC-1271 enrollment supports exactly one chain per signature. |
| `--strategy <id>` | Glider strategy id. |
| `--rpc`, `--key`, `--threshold-override` | As above. |
| `--portfolio-name <s>` | Optional display name. |
| `--dry-run` | Prints the exact curl commands and the signed payload; never calls Glider. Without `--typed-data` it prints the stage-1 curl and a stage-2 template (no RPC or keys needed). The curls reference `$GLIDER_API_KEY`; the key is never printed. |
| `--typed-data <file>` | Skips stage 1 and signs this file (a raw payload, or a saved stage-1 response). `--flow-id`, `--account-index`, `--agent-account-id` supply what the file lacks. |

Before signing, the typed data it is about to sign (domain, primaryType, message) is printed to stderr.

## Runbook: enrolling the Glider account under a Splits owner

1. **Get a staging key.** Email developers@glider.fi for a staging API key (needs at least the `enroll:write` scope; `portfolios:read` and `portfolios:write` are useful afterwards). Check it: `curl -H "x-api-key: $GLIDER_API_KEY" https://staging-api.glider.fi/v2/whoami`. Confirm with Glider that Base (8453) is enabled on that deployment, and which `strategyId` to use.
2. **Check the owner Splits account.** It must be deployed on Base and have EOA signers whose keys you hold for **at least `threshold` slots**:
   ```sh
   cast call $VAULT "getThreshold()(uint8)" --rpc-url $RPC
   cast call $VAULT "getSignerCount()(uint8)" --rpc-url $RPC
   cast call $VAULT "getSigner(uint8)((bytes32,bytes32))" 0 --rpc-url $RPC   # second word 0x00..00 => EOA
   ```
   Passkey-only accounts cannot use this tool (a WebAuthn assertion is needed per passkey signer). If an account has a mix, only the EOA slots can sign, so it works only if you hold enough of them to meet the threshold.
3. **Dry run.** `node glider-enroll.mjs --dry-run ...` and read the stage-1 body. `ownerAccountId` must be `eip155:0:<vault>`.
4. **Enroll on staging** (command above). The tool signs, verifies the signature against the vault with `isValidSignature`, and only then calls stage 2. Save the output: `portfolioId` and the `eip155:8453:0x...` smart account.
5. **Fund the Glider smart account** on Base (Glider has no deposit-builder route; transfer from the Splits account to the returned `eip155:8453:` address) and check `GET /v2/portfolios/{portfolioId}/positions`.
6. **Withdrawals use the same tool.** `POST /v2/portfolios/{portfolioId}/withdraw/signature` returns `typedData`; save it and run `sign-as-account.mjs --vault $VAULT --typed-data withdraw.json --key ...`, then send `typedData.message` unchanged plus the `signature` to `POST .../withdraw`. The authorization expires after 10 minutes, so have the keys ready. The `--typed-data` payload may also be the whole saved response.
7. **Custody stays in Splits.** Glider's owner is the Splits account, and Glider verifies by calling `isValidSignature` on it. That check follows the account's *current* signer set and threshold. The treasury can rotate signers (`addSigner`, `removeSigner`, `updateThreshold`; these are callable only by the account itself, i.e. through a normal Splits-signed transaction) and the keys used above stop mattering once they are removed. Rotate them out after enrollment if they were temporary, and make sure at least `threshold` keys you can reach are registered whenever a withdrawal needs signing. (This is how verification at enrollment and withdrawal behaves per Glider's docs; it is worth confirming with Glider that nothing caches the owner's signer set.)

## Tests

```sh
npm test         # ./test.sh
```

`test.sh` forks Base with anvil (`anvil --fork-url ${BASE_RPC_URL:-https://mainnet.base.org} --chain-id 8453`, killed on exit) and deploys fresh SmartVaults through the real factory with anvil's dev keys as signers (`createAccount(address owner, (bytes32,bytes32)[] signers, uint8 threshold, uint256 salt)`, each EOA signer encoded as `(leftPad32(address), 0x00..00)`):

- (a) threshold 1 with one EOA, (b) threshold 2 with two EOAs, (c) 2-of-3 signing with indices 0 and 2, (d) a vault with a passkey slot, (e) a Glider-withdrawal-shaped payload with a nested struct array
- for each success: exit 0 and `verified: true`; `hash` and local `W` recomputed independently with `cast keccak`/`abi-encode` (no viem) and compared; `W == vault.replaySafeHash`; `cast call isValidSignature == 0x1626ba7e`
- negative: wrong key for an index, empty signer slot, duplicate index, too few keys (with and without `--threshold-override`), passkey slot, address with no code, a contract that is not a SmartVault, a tampered signature and a valid signature checked against a different hash (`0xffffffff`)
- `glider-enroll --dry-run` prints both curls and a signature that validates on-chain, and never prints `GLIDER_API_KEY`
- the live `glider-enroll` path runs against `mock-glider.mjs`, a local stand-in for the two Glider endpoints that re-checks the signature with `isValidSignature`, enforces the round-trip fields and `flowId` idempotency. Glider itself is never contacted.
- a final grep proves no private key or API key appears in any captured output

It needs `anvil`, `cast`, `node`, `jq`, `curl` and network access to a Base RPC. The public RPC rate-limits, so the fork test keeps its calls to a handful; set `BASE_RPC_URL` to your own endpoint if it stalls.

## Limitations

- **EOA signers only.** Passkey (WebAuthn) signers and contract (nested ERC-1271) signers are detected and refused.
- **Deployed vaults only.** No ERC-6492 wrapping for counterfactual accounts.
- **One chain per ERC-1271 enrollment**, a Glider constraint. The wrap binds the signature to the vault address and chain id, so it cannot be replayed on another chain or account.
- **The wrap is specific to this SmartVault implementation.** If Splits changes it, the local-versus-onchain `replaySafeHash` assertion fails loudly instead of signing something wrong.
- **Keys are local software keys** read from the environment or argv (viem local accounts). There is no hardware-wallet or KMS path. A literal `--key` is visible to other local users in the process list, so use `env:`.
- **A signature is only valid for the current signer set.** If the signers or threshold change between signing and Glider's verification, it stops validating.
- **Glider was not called while building this.** There was no API key, so the Glider request and response shapes are taken from the OpenAPI file and guides as of 2026-10-15 and exercised only against the local mock. First use of the real staging API is the real test; `--dry-run` first.
- `ownerAccountId` is sent lowercase (Glider documents addresses as case-insensitive and lower-cases them).
